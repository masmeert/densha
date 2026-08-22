import Darwin
import Foundation

public final class DaemonClient {
    private let socket: UnixSocket
    private var nextID = 1

    public init(socket: UnixSocket) {
        self.socket = socket
    }

    public static func connect() throws -> DaemonClient {
        let path = Paths.socketFile.path
        do {
            return DaemonClient(socket: try UnixSocket.connect(to: path))
        } catch DenshaError.daemonNotRunning {
            try spawnDaemon()
            let deadline = Date().addingTimeInterval(10)
            var delay: UInt32 = 20_000
            while Date() < deadline {
                usleep(delay)
                delay = min(delay * 2, 250_000)
                if let socket = try? UnixSocket.connect(to: path) {
                    return DaemonClient(socket: socket)
                }
            }
            if let holder = lockHolder(), holder != getpid() {
                throw DenshaError.daemonUnreachable(
                    """
                    denshad (pid \(holder)) is already running but is not listening on \(path).
                    It is probably using a different DENSHA_SOCKET; stop it with \
                    `densha daemon stop` or unset the override.
                    """)
            }
            throw DenshaError.timedOut(
                "denshad to start listening on \(path) — see \(Paths.daemonLog.path)")
        }
    }

    public static func daemonCandidates() -> [String] {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["DENSHA_DAEMON"], !override.isEmpty {
            candidates.append(override)
        }
        if let dir = Bundle.main.executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent()
        {
            candidates.append(dir.appendingPathComponent("denshad").path)
            candidates.append(
                dir.deletingLastPathComponent().appendingPathComponent("Helpers/denshad").path)
        }
        candidates.append("/usr/local/bin/denshad")
        candidates.append("/opt/homebrew/bin/denshad")
        return candidates
    }

    public static func spawnDaemon() throws {
        guard
            let binary = daemonCandidates().first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        else {
            throw DenshaError.daemonUnreachable(
                "cannot find the denshad binary (looked in: "
                    + daemonCandidates().joined(separator: ", ") + ")")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var argv: [UnsafeMutablePointer<CChar>?] =
            [binary].map { s in
                s.withCString { strdup($0) }
            } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
            .map { s in s.withCString { strdup($0) } } + [nil]
        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, binary, &actions, &attr, &argv, &envp)
        guard rc == 0 else {
            throw DenshaError.daemonUnreachable(
                "spawning \(binary) failed: \(String(cString: strerror(rc)))")
        }
        var ignored: Int32 = 0
        waitpid(pid, &ignored, WNOHANG)
    }

    static func lockHolder() -> pid_t? {
        guard let text = try? String(contentsOf: Paths.lockFile, encoding: .utf8),
            let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            pid > 0, kill(pid, 0) == 0
        else { return nil }
        return pid
    }

    public static func isDaemonRunning() -> Bool {
        guard let socket = try? UnixSocket.connect(to: Paths.socketFile.path) else { return false }
        socket.close()
        return true
    }

    @discardableResult
    public static func waitForDaemonExit(timeout: Double = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isDaemonRunning() { return true }
            usleep(50_000)
        }
        return false
    }

    @discardableResult
    public func send(_ command: DaemonCommand) throws -> Response {
        let id = nextID
        nextID += 1
        let request = Request(id: id, command: command)
        try socket.write(Wire.line(request))
        while let message = try nextMessage() {
            if case .response(let response) = message, response.id == id {
                return response
            }
        }
        throw DenshaError.connectionClosed
    }

    public func nextMessage() throws -> ServerMessage? {
        guard let line = try socket.readLine() else { return nil }
        if line.isEmpty { return try nextMessage() }
        do {
            return try Wire.decoder.decode(ServerMessage.self, from: line)
        } catch {
            throw DenshaError.protocolViolation(
                String(decoding: line.prefix(200), as: UTF8.self))
        }
    }

    public func close() {
        socket.close()
    }
}
