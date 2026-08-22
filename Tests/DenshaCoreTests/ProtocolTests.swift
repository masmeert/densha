import Foundation
import Testing

@testable import DenshaCore

@Suite("Wire protocol")
struct ProtocolTests {
    @Test("every frame is exactly one line, so newline framing cannot break")
    func framingIsSingleLine() throws {
        let event = Event(
            event: .log, name: "web",
            line: LogLine(seq: 1, ts: 0, text: "a\nb\tc\u{1B}[32md\"e\\f"))
        let data = try Wire.line(event)
        #expect(data.last == 0x0A)
        #expect(data.dropLast().firstIndex(of: 0x0A) == nil)
    }

    @Test("a ports event survives a round trip")
    func portsEventRoundTrips() throws {
        let scanned = ScannedPort(
            port: 5432, pid: 812, processName: "postgres", conflictsWith: "db")
        let data = try Wire.line(Event(.ports([scanned])))
        let message = try Wire.decoder.decode(ServerMessage.self, from: data)
        guard case .event(let event) = message else {
            Issue.record("expected an event")
            return
        }
        #expect(try event.decoded() == .ports([scanned]))
    }

    @Test("a ports event without ports is rejected")
    func portsEventNeedsPorts() throws {
        let raw = Data(#"{"event":"ports"}"#.utf8)
        let event = try Wire.decoder.decode(Event.self, from: raw)
        #expect(throws: DenshaError.self) { try event.decoded() }
    }

    @Test("the ports request maps to the ports command")
    func portsRequestMapsToCommand() throws {
        #expect(try Request(id: 3, command: .ports).command() == .ports)
    }

    @Test("the kill request carries the port it must free")
    func killRequestCarriesItsPort() throws {
        #expect(try Request(id: 4, command: .kill(port: 3000)).command() == .kill(port: 3000))
    }

    @Test("a kill request without a port is rejected")
    func killRequestNeedsAPort() throws {
        let raw = Data(#"{"id":1,"op":"kill"}"#.utf8)
        let request = try Wire.decoder.decode(Request.self, from: raw)
        #expect(throws: DenshaError.self) { try request.command() }
    }

    @Test("a message carrying id decodes as a response")
    func discriminatesResponse() throws {
        let raw = Data(#"{"id":7,"ok":true}"#.utf8)
        let message = try Wire.decoder.decode(ServerMessage.self, from: raw)
        guard case .response(let response) = message else {
            Issue.record("expected a response")
            return
        }
        #expect(response.id == 7)
        #expect(response.ok)
    }

    @Test("a message carrying event decodes as an event")
    func discriminatesEvent() throws {
        let raw = Data(#"{"event":"status","services":[]}"#.utf8)
        let message = try Wire.decoder.decode(ServerMessage.self, from: raw)
        guard case .event(let event) = message else {
            Issue.record("expected an event")
            return
        }
        #expect(event.event == .status)
    }

    @Test("a message with neither key is rejected rather than guessed at")
    func rejectsAmbiguous() {
        #expect(throws: (any Error).self) {
            try Wire.decoder.decode(ServerMessage.self, from: Data(#"{"hello":1}"#.utf8))
        }
    }

    @Test("the hand-typeable request form works, as documented for nc")
    func handTypedRequest() throws {
        let raw = Data(#"{"id":1,"op":"status"}"#.utf8)
        let request = try Wire.decoder.decode(Request.self, from: raw)
        #expect(request.op == .status)
        #expect(request.names == nil)
    }

    @Test("typed commands round-trip through the loose wire format")
    func typedCommandsRoundTrip() throws {
        let commands: [DaemonCommand] = [
            .ping,
            .status,
            .start(names: nil),
            .stop(names: ["web"]),
            .restart(names: ["api"]),
            .reload,
            .logs(name: "web", tail: 200, follow: true),
            .watch,
            .input(name: "mobile", data: "r"),
            .shutdown,
        ]

        for command in commands {
            let wireRequest = Request(id: 1, command: command)
            let decodedRequest = try Wire.decoder.decode(
                Request.self, from: Wire.encoder.encode(wireRequest))
            #expect(try decodedRequest.command() == command)
        }
    }

    @Test("invalid wire field combinations are rejected at the boundary")
    func invalidCommandsAreRejected() {
        #expect(throws: (any Error).self) {
            try Wire.decoder.decode(Request.self, from: Data(#"{"id":1,"op":"logs"}"#.utf8))
                .command()
        }
        #expect(throws: (any Error).self) {
            try Wire.decoder.decode(
                Request.self, from: Data(#"{"id":1,"op":"input","name":"web"}"#.utf8)
            ).command()
        }
    }

    @Test("typed events round-trip through the loose wire format")
    func typedEventsRoundTrip() throws {
        let status = ServiceStatus(name: "web", state: .running)
        let line = LogLine(seq: 1, ts: 10, text: "ready")
        let events: [DaemonEvent] = [
            .status([status]),
            .log(name: "web", line: line),
            .reloaded(services: [status], warnings: ["missing cwd"]),
        ]

        for event in events {
            let wireEvent = Event(event)
            let decodedEvent = try Wire.decoder.decode(
                Event.self, from: Wire.encoder.encode(wireEvent))
            #expect(try decodedEvent.decoded() == event)
        }
    }

    @Test("status round-trips through JSON unchanged")
    func statusRoundTrip() throws {
        let original = ServiceStatus(
            name: "web", state: .unhealthy, pid: 42, pgid: 42, port: 3000,
            startedAt: 1_700_000_000, exitCode: nil, signal: nil, health: .failing,
            restarts: 2, command: "pnpm dev", cwd: "/tmp")
        let decoded = try Wire.decoder.decode(
            ServiceStatus.self, from: try Wire.encoder.encode(original))
        #expect(decoded == original)
    }

    @Test("all states and ops survive encoding", arguments: ServiceState.allCases)
    func stateRoundTrip(_ state: ServiceState) throws {
        let data = try Wire.encoder.encode(ServiceStatus(name: "x", state: state))
        #expect(try Wire.decoder.decode(ServiceStatus.self, from: data).state == state)
    }

    @Test("omitting names means all services")
    func namesOptional() throws {
        let request = try Wire.decoder.decode(
            Request.self, from: Data(#"{"id":1,"op":"start"}"#.utf8))
        let decoded = try Wire.decoder.decode(Request.self, from: try Wire.encoder.encode(request))
        #expect(decoded.names == nil)
    }

    @Test("stopping and starting both count as live, exited and failed do not")
    func liveness() {
        for state in [ServiceState.starting, .running, .unhealthy, .stopping] {
            #expect(ServiceStatus(name: "x", state: state).isLive, "\(state) should be live")
        }
        for state in [ServiceState.stopped, .exited, .failed] {
            #expect(!ServiceStatus(name: "x", state: state).isLive, "\(state) should not be live")
        }
    }
}

@Suite("ANSI")
struct AnsiTests {
    @Test("plain text passes through untouched and without allocating a rewrite")
    func plain() {
        #expect(Ansi.strip("hello world") == "hello world")
    }

    @Test("SGR colour codes are removed")
    func sgr() {
        #expect(Ansi.strip("\u{1B}[32mgreen\u{1B}[0m plain") == "green plain")
        #expect(Ansi.strip("\u{1B}[1;31;40mbold red\u{1B}[0m") == "bold red")
    }

    @Test("256-colour and truecolor forms are removed")
    func extendedColor() {
        #expect(Ansi.strip("\u{1B}[38;5;208morange\u{1B}[0m") == "orange")
        #expect(Ansi.strip("\u{1B}[38;2;255;128;0mrgb\u{1B}[0m") == "rgb")
    }

    @Test("cursor movement and erase sequences are removed")
    func cursorSequences() {
        #expect(Ansi.strip("\u{1B}[2K\u{1B}[1Gredrawn") == "redrawn")
        #expect(Ansi.strip("\u{1B}[?25lhidden\u{1B}[?25h") == "hidden")
    }

    @Test("OSC sequences terminated by BEL are removed")
    func oscBel() {
        #expect(Ansi.strip("\u{1B}]0;my title\u{07}after") == "after")
    }

    @Test("OSC sequences terminated by ST are removed")
    func oscST() {
        #expect(Ansi.strip("\u{1B}]8;;http://x\u{1B}\\link") == "link")
    }

    @Test("a truncated escape at end of input does not hang or crash")
    func truncated() {
        #expect(Ansi.strip("text\u{1B}") == "text")
        #expect(Ansi.strip("text\u{1B}[") == "text")
        #expect(Ansi.strip("text\u{1B}[32") == "text")
    }

    @Test("unescape turns typed backslash escapes into control bytes")
    func unescape() {
        #expect(Ansi.unescape("hello") == "hello")
        #expect(Ansi.unescape("\\n") == "\n")
        #expect(Ansi.unescape("\\r\\n") == "\r\n")
        #expect(Ansi.unescape("a\\tb") == "a\tb")
        #expect(Ansi.unescape("\\\\") == "\\")
        #expect(Ansi.unescape("\\e[32m") == "\u{1B}[32m")
    }

    @Test("unescape leaves unknown escapes alone rather than silently eating them")
    func unescapeUnknown() {
        #expect(Ansi.unescape("\\q") == "\\q")
    }

    @Test("a bare Expo key is sent verbatim, with no newline added")
    func expoKeys() {
        for key in ["i", "a", "r", "j"] {
            #expect(Ansi.unescape(key) == key)
        }
    }
}
