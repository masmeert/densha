import Foundation
import TOMLDecoder

struct ConfigFile: Decodable {
    var defaults: DefaultsSpec?
    var scan: ScanSpec?
    var project: [ProjectSpec]?
    var service: [ServiceSpec]?
}

struct ScanSpec: Decodable {
    var enabled: Bool?
    var ignorePorts: [Int]?
    var ignoreProcesses: [String]?

    enum CodingKeys: String, CodingKey {
        case enabled
        case ignorePorts = "ignore_ports"
        case ignoreProcesses = "ignore_processes"
    }
}

struct DefaultsSpec: Decodable {
    var shell: String?
    var shellArgs: [String]?
    var stopTimeout: Double?
    var restartGrace: Int?

    enum CodingKeys: String, CodingKey {
        case shell
        case shellArgs = "shell_args"
        case stopTimeout = "stop_timeout"
        case restartGrace = "restart_grace"
    }
}

struct ProjectSpec: Decodable {
    var name: String
    var cwd: String?
    var service: [ServiceSpec]?
}

struct ServiceSpec: Decodable {
    var name: String
    var cwd: String?
    var command: String
    var port: Int?
    var autostart: Bool?
    var env: [String: String]?
    var shell: String?
    var shellArgs: [String]?
    var stopTimeout: Double?
    var restartGrace: Int?
    var health: HealthSpec?

    enum CodingKeys: String, CodingKey {
        case name, cwd, command, port, autostart, env, shell, health
        case shellArgs = "shell_args"
        case stopTimeout = "stop_timeout"
        case restartGrace = "restart_grace"
    }
}

struct HealthSpec: Decodable {
    var type: String
    var port: Int?
    var path: String?
    var interval: Double?
    var timeout: Double?
}

public enum HealthKind: String, Codable, Sendable {
    case tcp, http
}

public struct ResolvedHealth: Sendable, Equatable {
    public let kind: HealthKind
    public let port: Int
    public let path: String
    public let interval: Double
    public let timeout: Double
}

public struct ResolvedService: Sendable, Equatable {
    public let name: String
    public let cwd: String
    public let command: String
    public let port: Int?
    public let autostart: Bool
    public let env: [String: String]
    public let shell: String
    public let shellArgs: [String]
    public let stopTimeout: Double
    public let restartGrace: Int
    public let health: ResolvedHealth?

    public var argv: [String] { [shell] + shellArgs + [command] }
}

public struct PortScanRules: Sendable, Equatable {
    public static let systemProcessNames: Set<String> = [
        "AirPlayXPCHelper",
        "ControlCenter",
        "rapportd",
        "remoted",
        "sharingd",
    ]

    public static let `default` = PortScanRules()

    public let enabled: Bool
    public let ignoredPorts: Set<Int>
    public let ignoredProcessNames: Set<String>

    public init(
        enabled: Bool = true, ignoredPorts: Set<Int> = [], ignoredProcessNames: Set<String> = []
    ) {
        self.enabled = enabled
        self.ignoredPorts = ignoredPorts
        self.ignoredProcessNames = ignoredProcessNames
    }

    public func ignores(port: Int, processName: String) -> Bool {
        ignoredPorts.contains(port)
            || ignoredProcessNames.contains(processName)
            || Self.systemProcessNames.contains(processName)
    }
}

public struct Defaults: Sendable {
    public static let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    public static let shellArgs = ["-lc"]
    public static let stopTimeout: Double = 5
    public static let restartGrace = 250
    public static let healthInterval: Double = 2
    public static let healthTimeout: Double = 1
    public static let healthPath = "/"
}

public struct Config: Sendable {
    public let services: [ResolvedService]
    public let warnings: [String]
    public let scan: PortScanRules

    public init(
        services: [ResolvedService], warnings: [String] = [], scan: PortScanRules = .default
    ) {
        self.services = services
        self.warnings = warnings
        self.scan = scan
    }

    public func service(named name: String) -> ResolvedService? {
        services.first { $0.name == name }
    }
}

public enum ConfigError: Error, CustomStringConvertible, Sendable {
    case missingFile(URL)
    case unreadable(URL, String)
    case syntax(String)
    case invalid(service: String?, reason: String)

    public var description: String {
        switch self {
        case .missingFile(let url):
            return "no config at \(url.path) — run `densha init` to create a starter file"
        case .unreadable(let url, let reason):
            return "cannot read \(url.path): \(reason)"
        case .syntax(let detail):
            return "services.toml is not valid TOML: \(detail)"
        case .invalid(let service, let reason):
            if let service { return "service \"\(service)\": \(reason)" }
            return reason
        }
    }
}

public enum ConfigLoader {
    static let allowedNameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    public static func loadTolerant(from url: URL = Paths.configFile) -> Config {
        do {
            return try load(from: url)
        } catch {
            return Config(services: [], warnings: ["\(error)"])
        }
    }

    public static func load(from url: URL = Paths.configFile) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.missingFile(url)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.unreadable(url, error.localizedDescription)
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> Config {
        let file: ConfigFile
        do {
            file = try TOMLDecoder().decode(ConfigFile.self, from: data)
        } catch let error as DecodingError {
            throw ConfigError.syntax(Self.describe(error))
        } catch {
            throw ConfigError.syntax("\(error)")
        }
        return try resolve(file)
    }

    static func resolve(_ file: ConfigFile) throws -> Config {
        var entries: [(spec: ServiceSpec, project: String?, projectCwd: String?)] = []
        var projectNames: [String] = []

        for spec in file.service ?? [] {
            entries.append((spec, nil, nil))
        }

        for project in file.project ?? [] {
            let name = project.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                throw ConfigError.invalid(service: nil, reason: "a project has an empty name")
            }
            guard name.unicodeScalars.allSatisfy({ allowedNameCharacters.contains($0) }) else {
                throw ConfigError.invalid(
                    service: nil,
                    reason: "project \"\(name)\": name may only contain letters, digits, dot, "
                        + "dash and underscore"
                )
            }
            guard !projectNames.contains(name) else {
                throw ConfigError.invalid(
                    service: nil, reason: "duplicate project name \"\(name)\"")
            }
            projectNames.append(name)

            var projectCwd: String?
            if let cwd = project.cwd {
                let expanded = expandTilde(cwd)
                guard expanded.hasPrefix("/") else {
                    throw ConfigError.invalid(
                        service: nil,
                        reason: "project \"\(name)\": cwd must be absolute or start with ~ "
                            + "(got \"\(cwd)\")"
                    )
                }
                projectCwd = expanded
            }

            let services = project.service ?? []
            guard !services.isEmpty else {
                throw ConfigError.invalid(
                    service: nil,
                    reason: "project \"\(name)\" has no [[project.service]] entries")
            }
            for spec in services {
                entries.append((spec, name, projectCwd))
            }
        }

        guard !entries.isEmpty else {
            throw ConfigError.invalid(service: nil, reason: "no [[service]] entries defined")
        }

        var seen = Set<String>()
        var portOwners: [String: [Int: String]] = [:]
        var resolved: [ResolvedService] = []
        var warnings: [String] = []

        for entry in entries {
            let service = try resolveService(
                entry.spec, project: entry.project, projectCwd: entry.projectCwd,
                defaults: file.defaults, warnings: &warnings)

            guard seen.insert(service.name).inserted else {
                throw ConfigError.invalid(service: service.name, reason: "duplicate service name")
            }
            if let port = service.port {
                let group = entry.project ?? ""
                if let owner = portOwners[group]?[port] {
                    warnings.append(
                        "services \"\(owner)\" and \"\(service.name)\" both declare port \(port) "
                            + "— only one of them can run at a time")
                } else {
                    portOwners[group, default: [:]][port] = service.name
                }
            }
            resolved.append(service)
        }

        for project in projectNames where seen.contains(project) {
            throw ConfigError.invalid(
                service: nil, reason: "\"\(project)\" is both a project and a service name")
        }

        return Config(services: resolved, warnings: warnings, scan: try scanRules(file.scan))
    }

    static func resolveService(
        _ spec: ServiceSpec, project: String?, projectCwd: String?,
        defaults: DefaultsSpec?, warnings: inout [String]
    ) throws -> ResolvedService {
        let shortName = spec.name.trimmingCharacters(in: .whitespaces)
        guard !shortName.isEmpty else {
            throw ConfigError.invalid(service: nil, reason: "a service has an empty name")
        }
        guard shortName.unicodeScalars.allSatisfy({ allowedNameCharacters.contains($0) }) else {
            throw ConfigError.invalid(
                service: shortName,
                reason: "name may only contain letters, digits, dot, dash and underscore"
            )
        }
        let name = ServiceName.qualified(project: project, name: shortName)
        guard !spec.command.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ConfigError.invalid(service: name, reason: "command is empty")
        }

        let cwd = try resolveCwd(spec.cwd, projectCwd: projectCwd, service: name)
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) {
            warnings.append("service \"\(name)\": cwd does not exist: \(cwd)")
        } else if !isDir.boolValue {
            warnings.append("service \"\(name)\": cwd is not a directory: \(cwd)")
        }

        let stopTimeout = spec.stopTimeout ?? defaults?.stopTimeout ?? Defaults.stopTimeout
        guard stopTimeout > 0 else {
            throw ConfigError.invalid(service: name, reason: "stop_timeout must be > 0")
        }
        let restartGrace = spec.restartGrace ?? defaults?.restartGrace ?? Defaults.restartGrace
        guard restartGrace >= 0 else {
            throw ConfigError.invalid(service: name, reason: "restart_grace must be >= 0")
        }
        if let port = spec.port {
            guard (1...65535).contains(port) else {
                throw ConfigError.invalid(service: name, reason: "port \(port) is out of range")
            }
        }

        var health: ResolvedHealth?
        if let h = spec.health {
            guard let kind = HealthKind(rawValue: h.type.lowercased()) else {
                throw ConfigError.invalid(
                    service: name,
                    reason: "health.type must be \"tcp\" or \"http\" (got \"\(h.type)\")"
                )
            }
            guard let healthPort = h.port ?? spec.port else {
                throw ConfigError.invalid(
                    service: name,
                    reason: "health check needs a port — set health.port or the service's port"
                )
            }
            guard (1...65535).contains(healthPort) else {
                throw ConfigError.invalid(
                    service: name, reason: "health.port \(healthPort) is out of range")
            }
            let interval = h.interval ?? Defaults.healthInterval
            let timeout = h.timeout ?? Defaults.healthTimeout
            guard interval > 0, timeout > 0 else {
                throw ConfigError.invalid(
                    service: name,
                    reason: "health.interval and health.timeout must be > 0"
                )
            }
            health = ResolvedHealth(
                kind: kind,
                port: healthPort,
                path: h.path ?? Defaults.healthPath,
                interval: interval,
                timeout: timeout
            )
        }

        return ResolvedService(
            name: name,
            cwd: cwd,
            command: spec.command,
            port: spec.port,
            autostart: spec.autostart ?? false,
            env: spec.env ?? [:],
            shell: expandTilde(spec.shell ?? defaults?.shell ?? Defaults.shell),
            shellArgs: spec.shellArgs ?? defaults?.shellArgs ?? Defaults.shellArgs,
            stopTimeout: stopTimeout,
            restartGrace: restartGrace,
            health: health
        )
    }

    static func resolveCwd(_ raw: String?, projectCwd: String?, service: String) throws -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            guard let projectCwd else {
                throw ConfigError.invalid(
                    service: service,
                    reason: "cwd is required — set it on the service or on its project")
            }
            return projectCwd
        }
        let expanded = expandTilde(raw)
        if expanded.hasPrefix("/") { return expanded }
        guard let projectCwd else {
            throw ConfigError.invalid(
                service: service,
                reason: "cwd must be absolute or start with ~ (got \"\(raw)\")"
            )
        }
        return URL(
            fileURLWithPath: expanded,
            relativeTo: URL(fileURLWithPath: projectCwd, isDirectory: true)
        ).standardizedFileURL.path
    }

    static func scanRules(_ spec: ScanSpec?) throws -> PortScanRules {
        guard let spec else { return .default }
        for port in spec.ignorePorts ?? [] where !(1...65535).contains(port) {
            throw ConfigError.invalid(
                service: nil, reason: "scan.ignore_ports: port \(port) is out of range")
        }
        return PortScanRules(
            enabled: spec.enabled ?? true,
            ignoredPorts: Set(spec.ignorePorts ?? []),
            ignoredProcessNames: Set(spec.ignoreProcesses ?? [])
        )
    }

    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
            && trimmed.unicodeScalars.allSatisfy { allowedNameCharacters.contains($0) }
    }

    public static func abbreviateTilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func expandTilde(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") {
            return NSHomeDirectory() + String(path.dropFirst(1))
        }
        return path
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let parts = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return parts.isEmpty ? "(top level)" : parts.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let ctx):
            return "missing required key \"\(key.stringValue)\" at \(path(ctx))"
        case .typeMismatch(let type, let ctx):
            return "wrong type at \(path(ctx)): expected \(readable(type))"
        case .valueNotFound(let type, let ctx):
            return "missing value at \(path(ctx)): expected \(readable(type))"
        case .dataCorrupted(let ctx):
            return ctx.debugDescription
        @unknown default:
            return "\(error)"
        }
    }

    static func readable(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: return "a string"
        case is Int.Type: return "an integer"
        case is Double.Type: return "a number"
        case is Bool.Type: return "true or false"
        case is [String].Type: return "an array of strings"
        default: return "\(type)"
        }
    }
}
