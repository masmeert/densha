import Darwin
import DenshaCore
import Foundation

/// Keeps signal sources alive for the process lifetime; a DispatchSource that goes
/// out of scope stops delivering.
final class SignalHandlers {
    private var sources: [DispatchSourceSignal] = []

    func install(_ signalNumber: Int32, handler: @escaping @Sendable () -> Void) {
        // The default disposition would terminate us before the source ever fires.
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: signalNumber, queue: DispatchQueue.global())
        source.setEventHandler(handler: handler)
        source.activate()
        sources.append(source)
    }
}

@main
struct Daemon {
    static func main() async {
        try? Paths.createDirectories()

        // Exactly one daemon per user. Clients race to spawn one on demand, so losing
        // this is an expected outcome, not an error.
        guard let lock = InstanceLock(path: Paths.lockFile) else {
            FileHandle.standardError.write(
                Data("denshad: another instance already holds \(Paths.lockFile.path)\n".utf8))
            exit(0)
        }

        redirectOutputIfDetached()

        let config = ConfigLoader.loadTolerant()
        for warning in config.warnings {
            log("config: \(warning)")
        }

        let supervisor = Supervisor(config: config)
        let server = SocketServer(supervisor: supervisor, path: Paths.socketFile.path)

        do {
            try await server.start()
        } catch {
            log("fatal: \(error)")
            exit(1)
        }
        log("listening on \(Paths.socketFile.path) (pid \(getpid()))")

        let handlers = SignalHandlers()
        let shutdown: @Sendable () -> Void = {
            Task {
                log("shutting down, stopping services")
                await supervisor.stopAll()
                await server.stop()
                exit(0)
            }
        }
        handlers.install(SIGTERM, handler: shutdown)
        handlers.install(SIGINT, handler: shutdown)
        // SIGHUP is the conventional "re-read your config" signal.
        handlers.install(SIGHUP) {
            Task {
                do {
                    let warnings = try await supervisor.reload()
                    log("reloaded config" + (warnings.isEmpty ? "" : "; \(warnings.count) warning(s)"))
                } catch {
                    log("reload failed: \(error)")
                }
            }
        }

        await supervisor.bootstrap()

        // Keep `lock` and `handlers` alive for the process lifetime.
        withExtendedLifetime((lock, handlers)) {}
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// When started by launchd or by the menubar app there is nowhere useful for
    /// stdout to go, so it is pointed at a log file instead of being discarded.
    static func redirectOutputIfDetached() {
        guard isatty(STDOUT_FILENO) == 0 else { return }
        let path = Paths.daemonLog.path
        let fd = open(path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        close(fd)
    }

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardOutput.write(Data("[\(stamp)] \(message)\n".utf8))
    }
}

func log(_ message: String) { Daemon.log(message) }
