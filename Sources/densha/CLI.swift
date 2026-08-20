import ArgumentParser
import Darwin
import DenshaCore
import Foundation

@main
struct Densha: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "densha",
        abstract: "Run your dev servers without keeping a terminal open.",
        version: DenshaVersion.marketing,
        subcommands: [
            Status.self, Ports.self, Kill.self, Start.self, Stop.self, Restart.self, Logs.self,
            Send.self, Reload.self, Init.self, Edit.self, DaemonControl.self, InstallCLI.self,
        ],
        defaultSubcommand: Status.self
    )
}

struct TargetOptions: ParsableArguments {
    @Argument(
        help: """
            Projects or services. A project name means all of its services; a service \
            is either project/name or a bare name when only one project defines it. \
            Omit and pass --all to target everything.
            """)
    var names: [String] = []

    @Flag(name: .long, help: "Apply to every configured service.")
    var all = false

    func resolved() throws -> [String]? {
        if all { return nil }
        guard !names.isEmpty else {
            throw ValidationError("name at least one project or service, or pass --all")
        }
        return names
    }
}

enum Style {
    static let color = isatty(STDOUT_FILENO) == 1

    static func paint(_ text: String, _ code: String) -> String {
        color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func dim(_ t: String) -> String { paint(t, "2") }
    static func bold(_ t: String) -> String { paint(t, "1") }
    static func red(_ t: String) -> String { paint(t, "31") }
    static func green(_ t: String) -> String { paint(t, "32") }
    static func yellow(_ t: String) -> String { paint(t, "33") }

    static func marker(_ state: ServiceState) -> String {
        switch state {
        case .running: return green("●")
        case .starting, .stopping: return yellow("◐")
        case .unhealthy: return yellow("●")
        case .stopped, .exited: return dim("○")
        case .failed: return red("✕")
        }
    }

    static func describe(_ s: ServiceStatus) -> String {
        switch s.state {
        case .running:
            return s.health == .passing ? "running" : "running"
        case .unhealthy: return yellow("unhealthy")
        case .starting: return "starting"
        case .stopping: return "stopping"
        case .stopped: return dim("stopped")
        case .exited: return dim("exited")
        case .failed:
            if let code = s.exitCode { return red("failed (exit \(code))") }
            if let sig = s.signal { return red("failed (signal \(sig))") }
            return red("failed")
        }
    }

    static func uptime(_ since: Double?) -> String {
        guard let since else { return "" }
        let seconds = Int(max(0, Date().timeIntervalSince1970 - since))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h\((seconds % 3600) / 60)m" }
        return "\(seconds / 86400)d"
    }

    static func pad(_ text: String, _ width: Int) -> String {
        var visible = 0
        var inEscape = false
        for ch in text {
            if ch == "\u{1B}" {
                inEscape = true
                continue
            }
            if inEscape {
                if ch == "m" { inEscape = false }
                continue
            }
            visible += 1
        }
        return text + String(repeating: " ", count: max(0, width - visible))
    }
}

func withClient<T>(_ body: (DaemonClient) throws -> T) throws -> T {
    let client = try DaemonClient.connect()
    defer { client.close() }
    return try body(client)
}

func printTable(_ services: [ServiceStatus]) {
    guard !services.isEmpty else {
        print(Style.dim("no services configured — run `densha init`"))
        return
    }
    let nameWidth = max(4, services.map(\.shortName.count).max() ?? 4)
    var currentProject: String??
    for service in services {
        if currentProject != .some(service.project) {
            currentProject = .some(service.project)
            if let project = service.project {
                print(Style.bold(project))
            }
        }
        var row = service.project == nil ? "" : "  "
        row += "\(Style.marker(service.state)) \(Style.pad(service.shortName, nameWidth))  "
        row += Style.pad(Style.describe(service), 22)
        row += Style.pad(service.port.map { ":\($0)" } ?? "", 7)
        if let pid = service.pid {
            row += Style.dim("pid \(pid)  ")
            row += Style.dim(Style.uptime(service.startedAt))
        }
        print(row)
    }
}

struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func reportFailure(_ response: Response) throws {
    if !response.ok, let error = response.error {
        throw RuntimeError(error)
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show service status.")

    @Flag(help: "Emit raw JSON instead of a table.")
    var json = false

    func run() async throws {
        guard DaemonClient.isDaemonRunning() else {
            if json {
                print(#"{"daemon":"stopped","services":[]}"#)
            } else {
                print(Style.dim("denshad is not running — `densha start <name>` will start it"))
            }
            return
        }
        try withClient { client in
            let response = try client.send(.status)
            let services = response.services ?? []
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let payload = try encoder.encode(services)
                print(String(decoding: payload, as: UTF8.self))
            } else {
                printTable(services)
                for warning in response.warnings ?? [] {
                    FileHandle.standardError.write(
                        Data((Style.yellow("warning: ") + warning + "\n").utf8))
                }
            }
        }
    }
}

struct Ports: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show listening ports that no configured service claims.",
        discussion: """
            Lists processes holding a local TCP port that none of densha's running \
            services owns — a database you started by hand, a container publishing a \
            port, another project's dev server.

            A port that a configured service declares but a foreign process holds is \
            marked with ! : that service cannot start until the port is free.

            Privileged ports below 1024 and ephemeral ports above 49151 are left out.
            """
    )

    @Flag(help: "Emit raw JSON instead of a table.")
    var json = false

    func run() async throws {
        guard DaemonClient.isDaemonRunning() else {
            if json {
                print(#"{"daemon":"stopped","ports":[]}"#)
            } else {
                print(Style.dim("denshad is not running — `densha daemon start` will start it"))
            }
            return
        }
        try withClient { client in
            let response = try client.send(.ports)
            try reportFailure(response)
            let ports = response.ports ?? []
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(ports), as: UTF8.self))
                return
            }
            guard !ports.isEmpty else {
                print(Style.dim("no unclaimed ports in use"))
                return
            }
            let nameWidth = max(4, ports.map(\.processName.count).max() ?? 4)
            for scanned in ports {
                var row = scanned.conflictsWith == nil ? "  " : Style.yellow("! ")
                row += Style.pad(":\(scanned.port)", 8)
                row += Style.pad(scanned.processName, nameWidth + 2)
                row += Style.pad(Style.dim("pid \(scanned.pid)"), 12)
                if let conflictsWith = scanned.conflictsWith {
                    row += Style.yellow("holds \(conflictsWith)'s port")
                }
                print(row)
            }
        }
    }
}

struct Kill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Kill the process holding an unclaimed port.",
        discussion: """
            Frees one of the ports `densha ports` lists: densha sends SIGTERM to the \
            process listening on it and follows with SIGKILL if the port is still held \
            when the stop timeout runs out.

            A port that one of densha's own running services holds is left alone — stop \
            the service instead. A port several processes share is only freed once every \
            one of them is gone, so the port may come back held by a sibling.
            """
    )

    @Argument(help: "The port to free, with or without a leading colon.")
    var port: String

    func run() async throws {
        let wanted = port.hasPrefix(":") ? String(port.dropFirst()) : port
        guard let number = Int(wanted), PortScanRules.scannablePorts.contains(number) else {
            throw ValidationError(
                "\(port) is not a port densha scans (\(PortScanRules.scannablePorts.lowerBound) to "
                    + "\(PortScanRules.scannablePorts.upperBound - 1))")
        }
        try withClient { client in
            let response = try client.send(.kill(port: number))
            try reportFailure(response)
            if let holder = (response.ports ?? []).first(where: { $0.port == number }) {
                print(
                    Style.yellow(
                        ":\(number) is still held by \(holder.processName) (pid \(holder.pid))"))
            } else {
                print(Style.dim(":\(number) is free"))
            }
        }
    }
}

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start a project or individual services.",
        discussion: """
            Projects that declare the same port — two Vite apps on 3000, say — are \
            mutually exclusive. Starting one stops whichever live service already \
            holds a port it needs, so `densha start storefront` is enough to switch \
            projects.
            """)
    @OptionGroup var target: TargetOptions

    func run() async throws {
        let names = try target.resolved()
        try withClient { client in
            let response = try client.send(.start(names: names))
            printTable(response.services ?? [])
            try reportFailure(response)
        }
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop one or more services.")
    @OptionGroup var target: TargetOptions

    func run() async throws {
        let names = try target.resolved()
        try withClient { client in
            let response = try client.send(.stop(names: names))
            printTable(response.services ?? [])
            try reportFailure(response)
        }
    }
}

struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restart one or more services.")
    @OptionGroup var target: TargetOptions

    func run() async throws {
        let names = try target.resolved()
        try withClient { client in
            let response = try client.send(.restart(names: names))
            printTable(response.services ?? [])
            try reportFailure(response)
        }
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a service's output.")

    @Argument(help: "Service name.") var name: String
    @Flag(name: .shortAndLong, help: "Keep streaming new output.") var follow = false
    @Option(name: .long, help: "How many recent lines to show (default 200).") var tail: Int = 200
    @Flag(name: .long, help: "Strip ANSI colour codes.") var noColor = false

    func run() async throws {
        try withClient { client in
            let response = try client.send(.logs(name: name, tail: tail, follow: follow))
            try reportFailure(response)
            for line in response.lines ?? [] { emit(line) }

            guard follow else { return }
            while let message = try client.nextMessage() {
                if case .event(let event) = message,
                    case .log(_, let line) = try event.decoded()
                {
                    emit(line)
                }
            }
        }
    }

    private func emit(_ line: LogLine) {
        let text = (noColor || !Style.color) ? Ansi.strip(line.text) : line.text
        print(text)
    }
}

struct Send: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send keystrokes to a running service.",
        discussion: """
            Writes directly to the service's terminal, which is how interactive dev \
            servers take commands. Expo for instance uses `i` to open iOS, `a` for \
            Android, `r` to reload and `j` to open the debugger.

            Escapes \\n, \\r, \\t and \\\\. A bare key sends no newline, so `densha send \
            mobile i` behaves exactly like pressing i in the terminal.
            """
    )

    @Argument(help: "Service name.") var name: String
    @Argument(help: "Keys to send.") var keys: String
    @Flag(name: .shortAndLong, help: "Append a newline.") var newline = false

    func run() async throws {
        var payload = Ansi.unescape(keys)
        if newline { payload += "\n" }
        try withClient { client in
            try reportFailure(try client.send(.input(name: name, data: payload)))
        }
    }
}

struct Reload: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Re-read services.toml without stopping anything.")

    func run() async throws {
        try withClient { client in
            let response = try client.send(.reload)
            try reportFailure(response)
            for warning in response.warnings ?? [] {
                print(Style.yellow("warning: ") + warning)
            }
            printTable(response.services ?? [])
        }
    }
}

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write a starter services.toml.")

    @Flag(name: .long, help: "Overwrite an existing file.") var force = false

    func run() async throws {
        try Paths.createDirectories()
        let url = Paths.configFile
        if FileManager.default.fileExists(atPath: url.path), !force {
            throw ValidationError("\(url.path) already exists — pass --force to overwrite")
        }
        try Template.starter.write(to: url, atomically: true, encoding: .utf8)
        print("wrote \(url.path)")
    }
}

struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open services.toml in $EDITOR, then reload.")

    func run() async throws {
        let url = Paths.configFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("no config yet — run `densha init` first")
        }
        let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "vi"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-lc", "\(editor) \(url.path.replacingOccurrences(of: " ", with: "\\ "))",
        ]
        try process.run()
        process.waitUntilExit()

        guard DaemonClient.isDaemonRunning() else { return }
        try withClient { client in
            let response = try client.send(.reload)
            if let error = response.error { print(Style.red("reload failed: ") + error) }
        }
    }
}

struct DaemonControl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Inspect and control the background daemon.",
        subcommands: [
            DaemonStatus.self, DaemonStart.self, DaemonStop.self,
            DaemonInstall.self, DaemonUninstall.self,
        ]
    )
}

struct DaemonStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Is the daemon running?")

    func run() async throws {
        if DaemonClient.isDaemonRunning() {
            print("\(Style.green("●")) denshad running, socket \(Paths.socketFile.path)")
        } else {
            print("\(Style.dim("○")) denshad not running")
        }
    }
}

struct DaemonStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start", abstract: "Start the daemon if it is not already up.")

    func run() async throws {
        if DaemonClient.isDaemonRunning() {
            print("already running")
            return
        }
        let client = try DaemonClient.connect()
        defer { client.close() }
        print("started")
    }
}

struct DaemonStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Stop all services and shut the daemon down.")

    func run() async throws {
        guard DaemonClient.isDaemonRunning() else {
            print("not running")
            return
        }
        try withClient { client in
            _ = try? client.send(.shutdown)
        }
        guard DaemonClient.waitForDaemonExit() else {
            throw RuntimeError("denshad acknowledged shutdown but is still listening")
        }
        usleep(700_000)
        if DaemonClient.isDaemonRunning() {
            print("stopped — but a new denshad is already running")
            print("Densha.app restarts it automatically; quit the app to stop it for good.")
            return
        }
        print("stopped")
    }
}

struct DaemonInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Start denshad at login via launchd.",
        discussion: """
            Installs a LaunchAgent so the daemon — and any service marked             autostart — comes up when you log in, without opening the app.

            The agent restarts denshad if it crashes, but not if you stop it             deliberately with `densha daemon stop`.
            """)

    func run() async throws {
        let path = try LaunchAgent.install()
        print("installed \(LaunchAgent.plistURL.path)")
        print("  -> \(path)")
        if DaemonClient.isDaemonRunning() {
            print("denshad is running")
        }
    }
}

struct DaemonUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall", abstract: "Stop starting denshad at login.")

    func run() async throws {
        guard LaunchAgent.isInstalled else {
            print("no LaunchAgent installed")
            return
        }
        try LaunchAgent.uninstall()
        print("removed \(LaunchAgent.plistURL.path)")
    }
}

struct InstallCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-cli",
        abstract: "Symlink this densha binary onto your PATH.")

    func run() async throws {
        let source = CLIInstaller.currentExecutable()
        let link = try CLIInstaller.install(source: source)
        print("linked \(link) -> \(source)")
        if !ProcessInfo.processInfo.environment["PATH", default: ""]
            .split(separator: ":").contains(where: {
                $0 == link.replacingOccurrences(of: "/densha", with: "")
            })
        {
            print(
                "note: \(link.replacingOccurrences(of: "/densha", with: "")) is not on your PATH yet"
            )
        }
    }
}
