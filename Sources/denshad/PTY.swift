import Darwin
import DenshaCore
import Foundation

struct SpawnedChild {
    let pid: pid_t
    let master: Int32
}

enum SpawnError: Error, CustomStringConvertible {
    case cwdUnusable(String, String)
    case syscall(String, Int32)
    case ptsname
    case spawnFailed(String, Int32)

    var description: String {
        switch self {
        case .cwdUnusable(let path, let why):
            return "cannot use cwd \(path): \(why)"
        case .syscall(let name, let code):
            return "\(name) failed: \(String(cString: strerror(code))) (errno \(code))"
        case .ptsname:
            return "ptsname() returned no path for the pty master"
        case .spawnFailed(let binary, let code):
            return "could not spawn \(binary): \(String(cString: strerror(code))) (\(code))"
        }
    }
}

enum PTYSpawner {
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

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw SpawnError.syscall("posix_openpt", errno) }
        var ok = false
        defer { if !ok { close(master) } }

        guard grantpt(master) == 0 else { throw SpawnError.syscall("grantpt", errno) }
        guard unlockpt(master) == 0 else { throw SpawnError.syscall("unlockpt", errno) }
        guard let namePtr = ptsname(master) else { throw SpawnError.ptsname }
        let slavePath = String(cString: namePtr)

        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        let slave = open(slavePath, O_RDWR | O_NOCTTY)
        guard slave >= 0 else { throw SpawnError.syscall("open(\(slavePath))", errno) }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        posix_spawn_file_actions_addchdir(&actions, svc.cwd)
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
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

        close(slave)

        guard rc == 0 else { throw SpawnError.spawnFailed(svc.shell, rc) }

        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        ok = true
        return SpawnedChild(pid: pid, master: master)
    }

    static func environment(for svc: ResolvedService) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        if env["HOME"]?.isEmpty ?? true { env["HOME"] = NSHomeDirectory() }
        if env["USER"]?.isEmpty ?? true { env["USER"] = NSUserName() }
        if env["LOGNAME"]?.isEmpty ?? true { env["LOGNAME"] = NSUserName() }
        env["SHELL"] = svc.shell

        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["COLUMNS"] = String(columns)
        env["LINES"] = String(rows)

        env["DENSHA_SERVICE"] = svc.shortName
        if let project = svc.project { env["DENSHA_PROJECT"] = project }
        if let port = svc.port { env["DENSHA_PORT"] = String(port) }
        env.removeValue(forKey: "DENSHA_SOCKET")

        for (key, value) in svc.env { env[key] = value }
        return env
    }
}
