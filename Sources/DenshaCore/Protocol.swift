import Foundation

// NDJSON: exactly one JSON object per line, in both directions. Deliberately flat
// rather than an enum-with-associated-values so the whole protocol stays typeable
// by hand: `echo '{"id":1,"op":"status"}' | nc -U ~/.local/state/densha/denshad.sock`

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
    /// nil means "all services" for start/stop/restart.
    public var names: [String]?
    public var name: String?
    public var tail: Int?
    public var follow: Bool?
    /// Raw bytes to write to the service's PTY master (the `input` op).
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
    /// Never started, or stopped on purpose.
    case stopped
    /// Spawned; not yet confirmed healthy. `expo run:ios` can sit here for minutes
    /// during a native build, so nothing may time this state out.
    case starting
    case running
    /// Alive, but its health probe is failing.
    case unhealthy
    /// SIGTERM sent, waiting for it to go away (or for the SIGKILL deadline).
    case stopping
    /// Exited 0 on its own.
    case exited
    /// Exited non-zero, or was killed by a signal we did not send.
    case failed
}

public enum HealthState: String, Codable, Sendable {
    case none, pending, passing, failing
}

public struct ServiceStatus: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var state: ServiceState
    public var pid: Int32?
    /// Equal to pid: every service is spawned as a session leader so the whole
    /// tree can be signalled with kill(-pgid).
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
    /// Raw text with ANSI escapes preserved; rendering decides what to do with them.
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
        /// Config was re-read; specs may have changed.
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

/// A client reads responses and pushed events off the same connection. They are
/// told apart structurally: responses carry "id", events carry "event".
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
        // Newline-delimited framing means the payload itself must never contain one.
        e.outputFormatting = []
        return e
    }()

    public static let decoder = JSONDecoder()

    /// Encodes one message plus its terminating newline.
    public static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}
