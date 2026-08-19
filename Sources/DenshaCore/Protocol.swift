import Foundation

public enum Op: String, Codable, Sendable {
    case ping
    case status
    case start
    case stop
    case restart
    case reload
    case logs
    case watch
    case input
    case shutdown
}

public struct Request: Codable, Sendable {
    public var id: Int
    public var op: Op
    public var names: [String]?
    public var name: String?
    public var tail: Int?
    public var follow: Bool?
    public var data: String?

    public init(
        id: Int, op: Op, names: [String]? = nil, name: String? = nil,
        tail: Int? = nil, follow: Bool? = nil, data: String? = nil
    ) {
        self.id = id
        self.op = op
        self.names = names
        self.name = name
        self.tail = tail
        self.follow = follow
        self.data = data
    }
}

public enum ServiceState: String, Codable, Sendable, CaseIterable {
    case stopped
    case starting
    case running
    case unhealthy
    case stopping
    case exited
    case failed
}

public enum HealthState: String, Codable, Sendable {
    case none, pending, passing, failing
}

public struct ServiceStatus: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var state: ServiceState
    public var pid: Int32?
    public var pgid: Int32?
    public var port: Int?
    public var startedAt: Double?
    public var exitCode: Int32?
    public var signal: Int32?
    public var health: HealthState
    public var restarts: Int
    public var command: String
    public var cwd: String

    public var id: String { name }

    public init(
        name: String, state: ServiceState, pid: Int32? = nil, pgid: Int32? = nil,
        port: Int? = nil, startedAt: Double? = nil, exitCode: Int32? = nil,
        signal: Int32? = nil, health: HealthState = .none, restarts: Int = 0,
        command: String = "", cwd: String = ""
    ) {
        self.name = name
        self.state = state
        self.pid = pid
        self.pgid = pgid
        self.port = port
        self.startedAt = startedAt
        self.exitCode = exitCode
        self.signal = signal
        self.health = health
        self.restarts = restarts
        self.command = command
        self.cwd = cwd
    }

    public var isLive: Bool {
        switch state {
        case .starting, .running, .unhealthy, .stopping: return true
        case .stopped, .exited, .failed: return false
        }
    }
}

public struct LogLine: Codable, Sendable, Equatable, Identifiable {
    public var seq: UInt64
    public var ts: Double
    public var text: String

    public var id: UInt64 { seq }

    public init(seq: UInt64, ts: Double, text: String) {
        self.seq = seq
        self.ts = ts
        self.text = text
    }
}

public struct Response: Codable, Sendable {
    public var id: Int
    public var ok: Bool
    public var error: String?
    public var services: [ServiceStatus]?
    public var lines: [LogLine]?
    public var warnings: [String]?

    public init(
        id: Int, ok: Bool, error: String? = nil, services: [ServiceStatus]? = nil,
        lines: [LogLine]? = nil, warnings: [String]? = nil
    ) {
        self.id = id
        self.ok = ok
        self.error = error
        self.services = services
        self.lines = lines
        self.warnings = warnings
    }

    public static func failure(id: Int, _ message: String) -> Response {
        Response(id: id, ok: false, error: message)
    }
}

public struct Event: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case status
        case log
        case reloaded
    }

    public var event: Kind
    public var services: [ServiceStatus]?
    public var name: String?
    public var line: LogLine?

    public init(
        event: Kind, services: [ServiceStatus]? = nil, name: String? = nil, line: LogLine? = nil
    ) {
        self.event = event
        self.services = services
        self.name = name
        self.line = line
    }
}

public enum ServerMessage: Sendable {
    case response(Response)
    case event(Event)
}

extension ServerMessage: Decodable {
    private enum Probe: String, CodingKey {
        case id, event
    }

    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: Probe.self)
        if keys.contains(.event) {
            self = .event(try Event(from: decoder))
        } else if keys.contains(.id) {
            self = .response(try Response(from: decoder))
        } else {
            throw DenshaError.protocolViolation("message has neither \"id\" nor \"event\"")
        }
    }
}

public enum Wire {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    public static let decoder = JSONDecoder()

    public static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}
