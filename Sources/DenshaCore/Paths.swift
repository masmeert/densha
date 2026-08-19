import Foundation

/// Well-known filesystem locations. XDG-style layout: hand-edited config under
/// `~/.config`, machine-managed runtime state under `~/.local/state`.
public enum Paths {
    public static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public static var configDir: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("densha")
        }
        return home.appendingPathComponent(".config/densha", isDirectory: true)
    }

    public static var stateDir: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("densha")
        }
        return home.appendingPathComponent(".local/state/densha", isDirectory: true)
    }

    public static var configFile: URL { configDir.appendingPathComponent("services.toml") }
    public static var logDir: URL { stateDir.appendingPathComponent("logs", isDirectory: true) }
    public static var lockFile: URL { stateDir.appendingPathComponent("denshad.lock") }
    public static var daemonLog: URL { stateDir.appendingPathComponent("denshad.log") }

    /// Overridable so tests can run against a throwaway socket without touching
    /// a real daemon the developer may have running.
    public static var socketFile: URL {
        if let override = ProcessInfo.processInfo.environment["DENSHA_SOCKET"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return stateDir.appendingPathComponent("denshad.sock")
    }

    public static func logFile(for service: String) -> URL {
        logDir.appendingPathComponent("\(service).log")
    }

    public static func createDirectories() throws {
        for dir in [configDir, stateDir, logDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// `sockaddr_un.sun_path` is 104 bytes on Darwin. Fail loudly and early rather
    /// than letting bind() truncate the path and bind somewhere surprising.
    public static let maxSocketPathLength = 103

    public static func validateSocketPath(_ url: URL) throws {
        let bytes = Array(url.path.utf8)
        if bytes.count > maxSocketPathLength {
            throw DenshaError.socketPathTooLong(path: url.path, length: bytes.count)
        }
    }
}

public enum DenshaError: Error, CustomStringConvertible, Sendable {
    case socketPathTooLong(path: String, length: Int)
    case daemonNotRunning
    case daemonUnreachable(String)
    case connectionClosed
    case protocolViolation(String)
    case timedOut(String)
    case noSuchService(String)
    case serviceNotRunning(String)

    public var description: String {
        switch self {
        case let .socketPathTooLong(path, length):
            return "socket path is \(length) bytes, max is \(Paths.maxSocketPathLength): \(path)"
        case .daemonNotRunning:
            return "denshad is not running"
        case let .daemonUnreachable(reason):
            return "cannot reach denshad: \(reason)"
        case .connectionClosed:
            return "connection closed by denshad"
        case let .protocolViolation(detail):
            return "unexpected message from denshad: \(detail)"
        case let .timedOut(what):
            return "timed out waiting for \(what)"
        case let .noSuchService(name):
            return "no such service: \(name)"
        case let .serviceNotRunning(name):
            return "\(name) is not running"
        }
    }
}
