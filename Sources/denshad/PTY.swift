import Darwin
import DenshaCore
import Foundation

/// A child running on its own pseudo-terminal, in its own session.
struct SpawnedChild {
    let pid: pid_t
    /// Read end of the child's combined stdout+stderr. Non-blocking.
    let master: Int32
}

enum SpawnError: Error, CustomStringConvertible {
    case cwdUnusable(String, String)
    case syscall(String, Int32)
    case ptsname
    case spawnFailed(String, Int32)

    var description: String {
        switch self {
        case let .cwdUnusable(path, why):
            return "cannot use cwd \(path): \(why)"
        case let .syscall(name, code):
            return "\(name) failed: \(String(cString: strerror(code))) (errno \(code))"
        case .ptsname:
            return "ptsname() returned no path for the pty master"
        case let .spawnFailed(binary, code):
            // posix_spawn reports the failure reason as its return value, not errno.
            return "could not spawn \(binary): \(String(cString: strerror(code))) (\(code))"
        }
    }
}

enum PTYSpawner {
    /// Fixed terminal geometry. Dev tools lay out against this, and it never
    /// changes, so their output stays stably wrapped.
    static let columns: UInt16 = 120
    static let rows: UInt16 = 40

    static func spawn(_ svc: ResolvedService) throws -> SpawnedChild {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: svc.cwd, isDirectory: &isDir) else {
            throw SpawnError.cwdUnusable(svc.cwd, "no such directory")
        }
        guard isDir.boolValue else {
            throw SpawnError.cwdUnusable(svc.cwd, "not a directory")
        }

        // 1. Master side.
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw SpawnError.syscall("posix_openpt", errno) }
        var ok = false
        defer { if !ok { close(master) } }

        guard grantpt(master) == 0 else { throw SpawnError.syscall("grantpt", errno) }
        guard unlockpt(master) == 0 else { throw SpawnError.syscall("unlockpt", errno) }
        guard let namePtr = ptsname(master) else { throw SpawnError.ptsname }
        let slavePath = String(cString: namePtr)

        // Keep the master out of any other exec we might do.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        // 2. Window size. On Darwin the master is not yet a tty — TIOCSWINSZ returns
        //    ENOTTY — until the slave has been opened at least once. So the parent
        //    opens the slave briefly, sets the size, and drops it again after spawn.
        //    Holding it any longer would stop the master from ever reporting EOF,
        //    because a slave fd would still be open after the child died.
        let slave = open(slavePath, O_RDWR | O_NOCTTY)
        guard slave >= 0 else { throw SpawnError.syscall("open(\(slavePath))", errno) }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)

        // 3. File actions.
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        posix_spawn_file_actions_addchdir(&actions, svc.cwd)
        // addopen, not adddup2 of our own slave fd: a session leader that opens a tty
        // *by path* acquires it as its controlling terminal, which is what lets tools
        // open /dev/tty and do proper interactive input.
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)

        // 4. Attributes.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // SETSID: child becomes session leader, so pgid == sid == pid and the whole
        //   subtree can be signalled with kill(-pid). This is what makes stopping
        //   `pnpm dev` actually release :3000 instead of orphaning node.
        // CLOEXEC_DEFAULT: everything except the fds named above is closed, so a
        //   service can never inherit our listening socket or another service's pty.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let env = environment(for: svc)
        var argv: [UnsafeMutablePointer<CChar>?] =
            svc.argv.map { s in s.withCString { strdup($0) } } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] =
            env.map { "\($0.key)=\($0.value)" }.map { s in s.withCString { strdup($0) } } + [nil]
        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, svc.shell, &actions, &attr, &argv, &envp)

        // The child has its own fds now; ours would only keep the pty alive.
        close(slave)

        guard rc == 0 else { throw SpawnError.spawnFailed(svc.shell, rc) }

        // Non-blocking so the read source can drain without ever parking a thread.
        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        ok = true
        return SpawnedChild(pid: pid, master: master)
    }

    /// The child's environment. A launchd-started daemon inherits almost nothing, so
    /// the essentials are filled in explicitly; the login shell then supplies PATH
    /// and any version-manager shims.
    static func environment(for svc: ResolvedService) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        if env["HOME"]?.isEmpty ?? true { env["HOME"] = NSHomeDirectory() }
        if env["USER"]?.isEmpty ?? true { env["USER"] = NSUserName() }
        if env["LOGNAME"]?.isEmpty ?? true { env["LOGNAME"] = NSUserName() }
        env["SHELL"] = svc.shell

        // There is a real terminal on the other end, so advertise it. Tools detect
        // color via isatty() and then consult TERM for how much of it they may use.
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["COLUMNS"] = String(columns)
        env["LINES"] = String(rows)

        env["DENSHA_SERVICE"] = svc.name
        if let port = svc.port { env["DENSHA_PORT"] = String(port) }
        // Our own control-channel override must not reach a child, or a service that
        // shells out to `densha` would talk to the wrong daemon.
        env.removeValue(forKey: "DENSHA_SOCKET")

        // Service-specific env wins over everything above.
        for (key, value) in svc.env { env[key] = value }
        return env
    }
}
