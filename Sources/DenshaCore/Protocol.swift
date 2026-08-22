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
    case ports
    case kill
    case shutdown
}

public enum DaemonCommand: Sendable, Equatable {
    case ping
    case status
    case start(names: [String]?)
    case stop(names: [String]?)
    case restart(names: [String]?)
    case reload
    case logs(name: String, tail: Int?, follow: Bool)
    case watch
    case input(name: String, data: String)
    case ports
    case kill(port: Int)
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
    public var port: Int?

    public init(id: Int, command: DaemonCommand) {
        self.id = id
        switch command {
        case .ping:
            self.op = .ping
        case .status:
            self.op = .status
        case .start(let names):
            self.op = .start
            self.names = names
        case .stop(let names):
            self.op = .stop
            self.names = names
        case .restart(let names):
            self.op = .restart
            self.names = names
        case .reload:
            self.op = .reload
        case .logs(let name, let tail, let follow):
            self.op = .logs
            self.name = name
            self.tail = tail
            self.follow = follow
        case .watch:
            self.op = .watch
        case .input(let name, let data):
            self.op = .input
            self.name = name
            self.data = data
        case .ports:
            self.op = .ports
        case .kill(let port):
            self.op = .kill
            self.port = port
        case .shutdown:
            self.op = .shutdown
        }
    }

    public func command() throws -> DaemonCommand {
        switch op {
        case .ping: return .ping
        case .status: return .status
        case .start: return .start(names: names)
        case .stop: return .stop(names: names)
        case .restart: return .restart(names: names)
        case .reload: return .reload
        case .logs:
            guard let name else {
                throw DenshaError.protocolViolation("logs requires \"name\"")
            }
            return .logs(name: name, tail: tail, follow: follow ?? false)
        case .watch: return .watch
        case .input:
            guard let name, let data else {
                throw DenshaError.protocolViolation("input requires \"name\" and \"data\"")
            }
            return .input(name: name, data: data)
        case .ports: return .ports
        case .kill:
            guard let port else {
                throw DenshaError.protocolViolation("kill requires \"port\"")
            }
            return .kill(port: port)
        case .shutdown: return .shutdown
        }
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

public struct ScannedPort: Codable, Sendable, Equatable, Identifiable {
    public var port: Int
    public var pid: Int32
    public var processName: String
    public var conflictsWith: String?

    public var id: Int { port }

    public init(port: Int, pid: Int32, processName: String, conflictsWith: String? = nil) {
        self.port = port
        self.pid = pid
        self.processName = processName
        self.conflictsWith = conflictsWith
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
    public var ports: [ScannedPort]?

    public init(
        id: Int, ok: Bool, error: String? = nil, services: [ServiceStatus]? = nil,
        lines: [LogLine]? = nil, warnings: [String]? = nil, ports: [ScannedPort]? = nil
    ) {
        self.id = id
        self.ok = ok
        self.error = error
        self.services = services
        self.lines = lines
        self.warnings = warnings
        self.ports = ports
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
        case ports
    }

    public var event: Kind
    public var services: [ServiceStatus]?
    public var name: String?
    public var line: LogLine?
    public var warnings: [String]?
    public var ports: [ScannedPort]?

    public init(
        event: Kind, services: [ServiceStatus]? = nil, name: String? = nil, line: LogLine? = nil,
        warnings: [String]? = nil, ports: [ScannedPort]? = nil
    ) {
        self.event = event
        self.services = services
        self.name = name
        self.line = line
        self.warnings = warnings
        self.ports = ports
    }
}

public enum DaemonEvent: Sendable, Equatable {
    case status([ServiceStatus])
    case log(name: String, line: LogLine)
    case reloaded(services: [ServiceStatus], warnings: [String])
    case ports([ScannedPort])
}

extension Event {
    public init(_ event: DaemonEvent) {
        switch event {
        case .status(let services):
            self.init(event: .status, services: services)
        case .log(let name, let line):
            self.init(event: .log, name: name, line: line)
        case .reloaded(let services, let warnings):
            self.init(event: .reloaded, services: services, warnings: warnings)
        case .ports(let ports):
            self.init(event: .ports, ports: ports)
        }
    }

    public func decoded() throws -> DaemonEvent {
        switch event {
        case .status:
            guard let services else {
                throw DenshaError.protocolViolation("status event requires \"services\"")
            }
            return .status(services)
        case .log:
            guard let name, let line else {
                throw DenshaError.protocolViolation("log event requires \"name\" and \"line\"")
            }
            return .log(name: name, line: line)
        case .reloaded:
            guard let services else {
                throw DenshaError.protocolViolation("reloaded event requires \"services\"")
            }
            return .reloaded(services: services, warnings: warnings ?? [])
        case .ports:
            guard let ports else {
                throw DenshaError.protocolViolation("ports event requires \"ports\"")
            }
            return .ports(ports)
        }
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
    public static let encoder = JSONEncoder()

    public static let decoder = JSONDecoder()

    public static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}
