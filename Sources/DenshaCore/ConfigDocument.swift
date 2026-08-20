import Foundation

public struct HealthDraft: Sendable, Equatable {
    public var kind: HealthKind
    public var port: Int?
    public var path: String?

    public init(kind: HealthKind, port: Int? = nil, path: String? = nil) {
        self.kind = kind
        self.port = port
        self.path = path
    }
}

public struct ServiceDraft: Sendable, Equatable {
    public var name: String
    public var cwd: String?
    public var command: String
    public var port: Int?
    public var autostart: Bool
    public var health: HealthDraft?

    public init(
        name: String, cwd: String? = nil, command: String, port: Int? = nil,
        autostart: Bool = false, health: HealthDraft? = nil
    ) {
        self.name = name
        self.cwd = cwd
        self.command = command
        self.port = port
        self.autostart = autostart
        self.health = health
    }
}

public struct ProjectDraft: Sendable, Equatable {
    public var name: String
    public var cwd: String?
    public var services: [ServiceDraft]

    public init(name: String, cwd: String? = nil, services: [ServiceDraft]) {
        self.name = name
        self.cwd = cwd
        self.services = services
    }
}

public struct ConfigDocument {
    public private(set) var text: String

    public init(text: String) {
        self.text = text
    }

    public static func load(from url: URL = Paths.configFile) throws -> ConfigDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ConfigDocument(text: Template.starter)
        }
        do {
            return ConfigDocument(text: try String(contentsOf: url, encoding: .utf8))
        } catch {
            throw ConfigError.unreadable(url, error.localizedDescription)
        }
    }

    public func save(to url: URL = Paths.configFile) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public mutating func add(_ project: ProjectDraft) throws {
        guard !project.services.isEmpty else {
            throw ConfigError.invalid(
                service: nil, reason: "project \"\(project.name)\" needs at least one service")
        }
        try insert(TOML.block(project), at: lines.count)
    }

    public mutating func add(_ service: ServiceDraft, toProject project: String?) throws {
        guard let project else {
            try insert(TOML.block(service, header: "[[service]]", indent: ""), at: lines.count)
            return
        }
        guard let end = endOfProject(named: project) else {
            throw ConfigError.invalid(
                service: nil, reason: "no [[project]] named \"\(project)\" in services.toml")
        }
        try insert(TOML.block(service, header: "[[project.service]]", indent: "  "), at: end)
    }

    public mutating func replace(_ service: ServiceDraft, named qualified: String) throws {
        guard let block = serviceBlock(named: qualified) else {
            throw ConfigError.invalid(service: qualified, reason: "not found in services.toml")
        }
        var lines = self.lines
        lines.replaceSubrange(
            block.range,
            with: TOML.block(service, header: block.header, indent: block.indent)
                .components(separatedBy: "\n"))
        try commit(lines)
    }

    public mutating func remove(serviceNamed qualified: String) throws {
        guard let block = serviceBlock(named: qualified) else {
            throw ConfigError.invalid(service: qualified, reason: "not found in services.toml")
        }
        let project = ServiceName.project(of: qualified)
        var doomed = block.range
        if let project, let region = projectRegion(named: project),
            serviceHeaders(inProject: region).count == 1
        {
            doomed = region
        }

        var lines = self.lines
        while doomed.lowerBound > 0,
            lines[doomed.lowerBound - 1].trimmingCharacters(in: .whitespaces).isEmpty
        {
            doomed = doomed.lowerBound - 1..<doomed.upperBound
        }
        lines.removeSubrange(doomed)
        try commit(lines)
    }

    public func hasProject(named project: String) -> Bool {
        projectRegion(named: project) != nil
    }

    public func cwd(ofProject project: String) -> String? {
        guard let region = projectRegion(named: project) else { return nil }
        return TOML.value(
            ofKey: "cwd", in: lines, region: region.lowerBound + 1..<region.upperBound)
    }

    private var lines: [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private mutating func commit(_ lines: [String]) throws {
        let candidate = lines.joined(separator: "\n") + "\n"
        _ = try ConfigLoader.parse(Data(candidate.utf8))
        text = candidate
    }

    private mutating func insert(_ block: String, at index: Int) throws {
        var lines = self.lines
        var index = min(index, lines.count)
        while index > 0, lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            index -= 1
        }
        var incoming = block.components(separatedBy: "\n")
        if index > 0 { incoming.insert("", at: 0) }
        if index < lines.count { incoming.append("") }
        lines.insert(contentsOf: incoming, at: index)
        try commit(lines)
    }

    private func serviceBlock(named qualified: String) -> (
        range: Range<Int>, header: String, indent: String
    )? {
        let lines = self.lines
        let short = ServiceName.short(of: qualified)
        let candidates: [TOML.Header]
        if let project = ServiceName.project(of: qualified) {
            guard let region = projectRegion(named: project) else { return nil }
            candidates = serviceHeaders(inProject: region)
        } else {
            candidates = TOML.headers(in: lines).filter { $0.key == "service" }
        }

        let headers = TOML.headers(in: lines)
        for header in candidates {
            let end = headers.first { $0.index > header.index }?.index ?? lines.count
            guard TOML.value(ofKey: "name", in: lines, region: header.index + 1..<end) == short
            else { continue }
            var last = end
            while last > header.index + 1, isBlankOrComment(lines[last - 1]) { last -= 1 }
            let indent = String(
                lines[header.index].prefix { $0 == " " || $0 == "\t" })
            return (
                header.index..<last, lines[header.index].trimmingCharacters(in: .whitespaces),
                indent
            )
        }
        return nil
    }

    private func serviceHeaders(inProject region: Range<Int>) -> [TOML.Header] {
        TOML.headers(in: lines).filter {
            region.contains($0.index) && $0.key == "project.service"
        }
    }

    private func isBlankOrComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    private func endOfProject(named project: String) -> Int? {
        projectRegion(named: project)?.upperBound
    }

    private func projectRegion(named project: String) -> Range<Int>? {
        let lines = self.lines
        let headers = TOML.headers(in: lines)

        for (position, header) in headers.enumerated() where header.key == "project" {
            let ownKeys = header.index + 1..<lines.count
            guard TOML.value(ofKey: "name", in: lines, region: ownKeys) == project else { continue }
            let end =
                headers[(position + 1)...]
                .first { !$0.key.hasPrefix("project.") }?.index ?? lines.count
            return header.index..<end
        }
        return nil
    }
}

enum TOML {
    struct Header {
        let index: Int
        let key: String
    }

    static func headers(in lines: [String]) -> [Header] {
        var headers: [Header] = []
        var openBasicString = false
        var openLiteralString = false

        for (index, line) in lines.enumerated() {
            if !openBasicString && !openLiteralString {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("["), let key = key(ofHeader: trimmed) {
                    headers.append(Header(index: index, key: key))
                }
            }
            if line.components(separatedBy: "\"\"\"").count % 2 == 0 {
                openBasicString.toggle()
            }
            if line.components(separatedBy: "'''").count % 2 == 0 {
                openLiteralString.toggle()
            }
        }
        return headers
    }

    static func key(ofHeader line: String) -> String? {
        var characters = Array(line)
        var cursor = 0
        while cursor < characters.count, characters[cursor] == "[" { cursor += 1 }
        var key = ""
        var quoted = false
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "\"" { quoted.toggle() }
            if character == "]" && !quoted { return key.trimmingCharacters(in: .whitespaces) }
            key.append(character)
            cursor += 1
        }
        return nil
    }

    static func value(ofKey key: String, in lines: [String], region: Range<Int>) -> String? {
        for line in lines[region.clamped(to: lines.indices)] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard trimmed.hasPrefix(key) else { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            guard trimmed[trimmed.startIndex..<equals].trimmingCharacters(in: .whitespaces) == key
            else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(
                in: .whitespaces)
            guard value.hasPrefix("\""), value.count >= 2 else { continue }
            return String(value.dropFirst().prefix(while: { $0 != "\"" }))
        }
        return nil
    }

    static func block(_ project: ProjectDraft) -> String {
        var lines = ["[[project]]", "name = \(string(project.name))"]
        if let cwd = project.cwd, !cwd.isEmpty { lines.append("cwd = \(string(cwd))") }
        for service in project.services {
            lines.append("")
            lines.append(block(service, header: "[[project.service]]", indent: "  "))
        }
        return lines.joined(separator: "\n")
    }

    static func block(_ service: ServiceDraft, header: String, indent: String) -> String {
        var lines = [header, "name = \(string(service.name))"]
        if let cwd = service.cwd, !cwd.isEmpty { lines.append("cwd = \(string(cwd))") }
        lines.append("command = \(string(service.command))")
        if let port = service.port { lines.append("port = \(port)") }
        if service.autostart { lines.append("autostart = true") }
        if let health = service.health {
            var fields = ["type = \(string(health.kind.rawValue))"]
            if let port = health.port { fields.append("port = \(port)") }
            if health.kind == .http, let path = health.path, !path.isEmpty {
                fields.append("path = \(string(path))")
            }
            lines.append("health = { \(fields.joined(separator: ", ")) }")
        }
        return lines.map { indent + $0 }.joined(separator: "\n")
    }

    static func string(_ value: String) -> String {
        var quoted = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            default:
                if scalar.value < 0x20 {
                    quoted += String(format: "\\u%04X", scalar.value)
                } else {
                    quoted.unicodeScalars.append(scalar)
                }
            }
        }
        return quoted + "\""
    }
}
