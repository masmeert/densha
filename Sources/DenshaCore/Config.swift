import Foundation
import TOMLDecoder

// MARK: - On-disk shape

/// Mirrors services.toml exactly. Every overridable key is Optional here so that
/// "absent" stays distinguishable from "explicitly set to the default value" —
/// resolution against [defaults] depends on that difference.
struct ConfigFile: Decodable {
    var defaults: DefaultsSpec?
    var service: [ServiceSpec]?
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

struct ServiceSpec: Decodable {
    var name: String
    var cwd: String
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

// MARK: - Resolved shape

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

/// A service with every default already applied, paths expanded, and invariants
/// checked. The daemon only ever sees this type, so it never repeats the lookup.
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

    /// argv for posix_spawn. Running through a shell is what lets `command` be a
    /// normal shell string ("pnpm dev", pipelines, &&) instead of a pre-split argv.
    public var argv: [String] { [shell] + shellArgs + [command] }
}

public struct Defaults: Sendable {
    public static let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    /// Login shell, not interactive: see README troubleshooting. A daemon started by
    /// launchd inherits almost no environment, so some shell init must run.
    public static let shellArgs = ["-lc"]
    public static let stopTimeout: Double = 5
    public static let restartGrace = 250
    public static let healthInterval: Double = 2
    public static let healthTimeout: Double = 1
    public static let healthPath = "/"
}

public struct Config: Sendable {
    public let services: [ResolvedService]
    /// Non-fatal problems worth showing the user (e.g. a missing cwd) without
    /// refusing to load the whole file.
    public let warnings: [String]

    public init(services: [ResolvedService], warnings: [String] = []) {
        self.services = services
        self.warnings = warnings
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
        case let .missingFile(url):
            return "no config at \(url.path) — run `densha init` to create a starter file"
        case let .unreadable(url, reason):
            return "cannot read \(url.path): \(reason)"
        case let .syntax(detail):
            return "services.toml is not valid TOML: \(detail)"
        case let .invalid(service, reason):
            if let service { return "service \"\(service)\": \(reason)" }
            return reason
        }
    }
}

// MARK: - Loading

public enum ConfigLoader {
    /// Service names become log filenames and CLI arguments, so keep them boring.
    static let allowedNameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    /// For the daemon, which must come up even with no config yet: a client may well
    /// have spawned it before the user ever wrote services.toml, and refusing to
    /// start would leave the menubar unable to explain why.
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
        let specs = file.service ?? []
        guard !specs.isEmpty else {
            throw ConfigError.invalid(service: nil, reason: "no [[service]] entries defined")
        }

        let d = file.defaults
        var seen = Set<String>()
        var resolved: [ResolvedService] = []
        var warnings: [String] = []

        for spec in specs {
            let name = spec.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                throw ConfigError.invalid(service: nil, reason: "a service has an empty name")
            }
            guard name.unicodeScalars.allSatisfy({ allowedNameCharacters.contains($0) }) else {
                throw ConfigError.invalid(
                    service: name,
                    reason: "name may only contain letters, digits, dot, dash and underscore"
                )
            }
            guard seen.insert(name).inserted else {
                throw ConfigError.invalid(service: name, reason: "duplicate service name")
            }
            guard !spec.command.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ConfigError.invalid(service: name, reason: "command is empty")
            }

            let cwd = expandTilde(spec.cwd)
            guard cwd.hasPrefix("/") else {
                throw ConfigError.invalid(
                    service: name,
                    reason: "cwd must be absolute or start with ~ (got \"\(spec.cwd)\")"
                )
            }
            // A missing directory is a warning, not a hard failure: the config may
            // legitimately describe a repo that is not cloned on this machine yet,
            // and refusing to load would take down every other service too.
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) {
                warnings.append("service \"\(name)\": cwd does not exist: \(cwd)")
            } else if !isDir.boolValue {
                warnings.append("service \"\(name)\": cwd is not a directory: \(cwd)")
            }

            let stopTimeout = spec.stopTimeout ?? d?.stopTimeout ?? Defaults.stopTimeout
            guard stopTimeout > 0 else {
                throw ConfigError.invalid(service: name, reason: "stop_timeout must be > 0")
            }
            let restartGrace = spec.restartGrace ?? d?.restartGrace ?? Defaults.restartGrace
            guard restartGrace >= 0 else {
                throw ConfigError.invalid(service: name, reason: "restart_grace must be >= 0")
            }
            if let port = spec.port, !(1...65535).contains(port) {
                throw ConfigError.invalid(service: name, reason: "port \(port) is out of range")
            }

            var health: ResolvedHealth?
            if let h = spec.health {
                guard let kind = HealthKind(rawValue: h.type.lowercased()) else {
                    throw ConfigError.invalid(
                        service: name,
                        reason: "health.type must be \"tcp\" or \"http\" (got \"\(h.type)\")"
                    )
                }
                guard let hp = h.port ?? spec.port else {
                    throw ConfigError.invalid(
                        service: name,
                        reason: "health check needs a port — set health.port or the service's port"
                    )
                }
                guard (1...65535).contains(hp) else {
                    throw ConfigError.invalid(service: name, reason: "health.port \(hp) is out of range")
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
                    port: hp,
                    path: h.path ?? Defaults.healthPath,
                    interval: interval,
                    timeout: timeout
                )
            }

            resolved.append(
                ResolvedService(
                    name: name,
                    cwd: cwd,
                    command: spec.command,
                    port: spec.port,
                    autostart: spec.autostart ?? false,
                    env: spec.env ?? [:],
                    shell: expandTilde(spec.shell ?? d?.shell ?? Defaults.shell),
                    shellArgs: spec.shellArgs ?? d?.shellArgs ?? Defaults.shellArgs,
                    stopTimeout: stopTimeout,
                    restartGrace: restartGrace,
                    health: health
                )
            )
        }

        return Config(services: resolved, warnings: warnings)
    }

    public static func expandTilde(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") {
            return NSHomeDirectory() + String(path.dropFirst(1))
        }
        return path
    }

    /// DecodingError's default description leaks Swift type names; turn it into
    /// something that points at the TOML key the user actually mistyped.
    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let parts = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return parts.isEmpty ? "(top level)" : parts.joined(separator: ".")
        }
        switch error {
        case let .keyNotFound(key, ctx):
            return "missing required key \"\(key.stringValue)\" at \(path(ctx))"
        case let .typeMismatch(type, ctx):
            return "wrong type at \(path(ctx)): expected \(readable(type))"
        case let .valueNotFound(type, ctx):
            return "missing value at \(path(ctx)): expected \(readable(type))"
        case let .dataCorrupted(ctx):
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
