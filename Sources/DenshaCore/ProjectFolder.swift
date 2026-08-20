import Foundation

public struct ProjectFolder: Sendable, Equatable {
    public let path: String
    public let projectName: String
    public let command: String?

    public init(path: String, projectName: String, command: String?) {
        self.path = path
        self.projectName = projectName
        self.command = command
    }

    public static func inspect(_ url: URL) -> ProjectFolder {
        let directory = url.standardizedFileURL
        let manifest = PackageManifest(directory: directory)
        let name =
            manifest?.name
            ?? gitRepositoryName(near: directory)
            ?? directory.lastPathComponent
        return ProjectFolder(
            path: ConfigLoader.abbreviateTilde(directory.path),
            projectName: sanitized(name),
            command: manifest?.command
        )
    }

    public static func sanitized(_ raw: String) -> String {
        var name = ""
        for scalar in raw.unicodeScalars {
            if ConfigLoader.allowedNameCharacters.contains(scalar) {
                name.unicodeScalars.append(scalar)
            } else if !name.hasSuffix("-") {
                name.append("-")
            }
        }
        while name.hasPrefix("-") { name.removeFirst() }
        while name.hasSuffix("-") { name.removeLast() }
        return name
    }

    static func gitRepositoryName(near directory: URL) -> String? {
        var candidate = directory
        while candidate.path != "/" {
            let git = candidate.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: git.path) {
                let config = git.appendingPathComponent("config")
                if let text = try? String(contentsOf: config, encoding: .utf8),
                    let remote = remoteName(inGitConfig: text)
                {
                    return remote
                }
                return candidate.lastPathComponent
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    static func remoteName(inGitConfig text: String) -> String? {
        var inOrigin = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inOrigin = trimmed.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"
                continue
            }
            guard inOrigin, trimmed.hasPrefix("url"), let equals = trimmed.firstIndex(of: "=")
            else { continue }
            let remote = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            let last = remote.split(whereSeparator: { $0 == "/" || $0 == ":" }).last
            guard var name = last.map(String.init), !name.isEmpty else { continue }
            if name.hasSuffix(".git") { name.removeLast(4) }
            return name.isEmpty ? nil : name
        }
        return nil
    }
}

struct PackageManifest {
    let name: String?
    let command: String?

    init?(directory: URL) {
        let manifest = directory.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifest),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let declared = json["name"] as? String
        name = declared.map { $0.hasPrefix("@") ? String($0.split(separator: "/").last ?? "") : $0 }
            .flatMap { $0.isEmpty ? nil : $0 }

        let scripts = json["scripts"] as? [String: Any] ?? [:]
        guard let script = ["dev", "start"].first(where: { scripts[$0] != nil }) else {
            command = nil
            return
        }
        command = PackageManifest.runner(in: directory).command(script)
    }

    enum Runner: String {
        case npm, pnpm, yarn, bun

        func command(_ script: String) -> String {
            switch self {
            case .npm: return "npm run \(script)"
            case .pnpm: return "pnpm \(script)"
            case .yarn: return "yarn \(script)"
            case .bun: return "bun run \(script)"
            }
        }
    }

    static func runner(in directory: URL) -> Runner {
        let lockfiles: [(String, Runner)] = [
            ("pnpm-lock.yaml", .pnpm),
            ("yarn.lock", .yarn),
            ("bun.lock", .bun),
            ("bun.lockb", .bun),
            ("package-lock.json", .npm),
        ]
        for (file, runner) in lockfiles
        where FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(file).path)
        {
            return runner
        }
        return .npm
    }
}
