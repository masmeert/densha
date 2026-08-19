import Foundation

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

    public static var socketFile: URL {
        if let override = ProcessInfo.processInfo.environment["DENSHA_SOCKET"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return stateDir.appendingPathComponent("denshad.sock")
    }

    public static func logFile(for service: String) -> URL {
        var url = logDir
        for component in service.split(separator: ServiceName.separator) {
            url.appendPathComponent(String(component))
        }
        return url.appendingPathExtension("log")
    }

    public static func logFiles(for service: String) -> [URL] {
        let current = logFile(for: service)
        return [current.appendingPathExtension("1"), current]
    }

    public static func createDirectories() throws {
        for dir in [configDir, stateDir, logDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

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
    case commandFailed(String)
    case connectionClosed
    case protocolViolation(String)
    case timedOut(String)
    case noSuchService(String)
    case ambiguousTarget(String, matches: [String])
    case serviceNotRunning(String)
    case noLogFile(String)

    public var description: String {
        switch self {
        case .socketPathTooLong(let path, let length):
            return "socket path is \(length) bytes, max is \(Paths.maxSocketPathLength): \(path)"
        case .daemonNotRunning:
            return "denshad is not running"
        case .daemonUnreachable(let reason):
            return "cannot reach denshad: \(reason)"
        case .commandFailed(let reason):
            return reason
        case .connectionClosed:
            return "connection closed by denshad"
        case .protocolViolation(let detail):
            return "unexpected message from denshad: \(detail)"
        case .timedOut(let what):
            return "timed out waiting for \(what)"
        case .noSuchService(let name):
            return "no such service: \(name)"
        case .ambiguousTarget(let name, let matches):
            return "\(name) is ambiguous — did you mean \(matches.joined(separator: ", "))?"
        case .serviceNotRunning(let name):
            return "\(name) is not running"
        case .noLogFile(let name):
            return "no log file for \(name)"
        }
    }
}
