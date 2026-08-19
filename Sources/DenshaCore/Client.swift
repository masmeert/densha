import Darwin
import Foundation

/// Synchronous client for the daemon. Used directly by the CLI, and wrapped in an
/// actor by the menubar app.
public final class DaemonClient {
    private let socket: UnixSocket
    private var nextID = 1

    public init(socket: UnixSocket) {
        self.socket = socket
    }

    // MARK: - Connecting

    /// Connects, starting a daemon first if none is listening. Every client can do
    /// this, so the user never has to know the daemon exists.
    public static func connect(spawningIfNeeded: Bool = true, timeout: Double = 10) throws
        -> DaemonClient
    {
        let path = Paths.socketFile.path
        do {
            return DaemonClient(socket: try UnixSocket.connect(to: path))
        } catch DenshaError.daemonNotRunning where spawningIfNeeded {
            try spawnDaemon()
            // The daemon has to create its socket before we can connect, so poll
            // briefly rather than failing on the first attempt.
            let deadline = Date().addingTimeInterval(timeout)
            var delay: UInt32 = 20_000
            while Date() < deadline {
                usleep(delay)
                delay = min(delay * 2, 250_000)
                if let socket = try? UnixSocket.connect(to: path) {
                    return DaemonClient(socket: socket)
                }
            }
            // A spawned daemon that exits instantly is nearly always losing the
            // single-instance lock to one that is already up. Say so, instead of
            // reporting a bare timeout the user cannot act on.
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

    /// Locations to look for the daemon, in order. Bundled-alongside comes first so a
    /// Densha.app copy never depends on PATH or on a stale /usr/local/bin install.
    public static func daemonCandidates() -> [String] {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["DENSHA_DAEMON"], !override.isEmpty {
            candidates.append(override)
        }
        if let dir = Bundle.main.executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent()
        {
            // Next to us: the build directory, or a manual install.
            candidates.append(dir.appendingPathComponent("denshad").path)
            // Inside the app bundle: Contents/MacOS/Densha -> Contents/Helpers/denshad.
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
        // The daemon reopens its own log; it must not inherit our terminal, or killing
        // the CLI's terminal would take the daemon's output with it.
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // SETSID detaches it from our session, so it survives this shell closing.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var argv: [UnsafeMutablePointer<CChar>?] = [binary].map { s in
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
        // Reap immediately: the daemon detached itself, so this only clears the
        // short-lived intermediate, and never blocks.
        var ignored: Int32 = 0
        waitpid(pid, &ignored, WNOHANG)
    }

    /// The pid recorded in the instance lock, if a live process still holds it.
    static func lockHolder() -> pid_t? {
        guard let text = try? String(contentsOf: Paths.lockFile, encoding: .utf8),
            let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            pid > 0, kill(pid, 0) == 0
        else { return nil }
        return pid
    }

    /// True if something is listening, without starting anything.
    public static func isDaemonRunning() -> Bool {
        guard let socket = try? UnixSocket.connect(to: Paths.socketFile.path) else { return false }
        socket.close()
        return true
    }

    /// Blocks until nothing is listening any more. A shutdown reply only means the
    /// daemon accepted the request; it still has to stop every service first. Without
    /// this wait, the next command can connect to a dying daemon and get stale answers.
    @discardableResult
    public static func waitForDaemonExit(timeout: Double = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isDaemonRunning() { return true }
            usleep(50_000)
        }
        return false
    }

    // MARK: - Requests

    @discardableResult
    public func send(
        _ op: Op, names: [String]? = nil, name: String? = nil, tail: Int? = nil,
        follow: Bool? = nil, data: String? = nil
    ) throws -> Response {
        let id = nextID
        nextID += 1
        let request = Request(
            id: id, op: op, names: names, name: name, tail: tail, follow: follow, data: data)
        try socket.write(Wire.line(request))
        // Events can already be interleaved here, so skip past anything that is not
        // the reply we are waiting for.
        while let message = try nextMessage() {
            if case let .response(response) = message, response.id == id {
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
