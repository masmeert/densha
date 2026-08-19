import Darwin
import DenshaCore
import Foundation

/// Everything that can happen to a child, funnelled through one ordered stream.
/// Both dispatch sources for a service share a single serial queue, so the relative
/// order of "here is more output" and "it exited" is preserved — otherwise the last
/// few lines of a crash could arrive after the exit was already reported.
enum ProcessEvent: Sendable {
    case output(Data)
    case eof
    case exited(status: Int32)
}

/// Breaks the retain cycle a dispatch source's own handler would otherwise create
/// by referencing the source it belongs to.
final class SourceHolder: @unchecked Sendable {
    var read: DispatchSourceRead?
    var exit: DispatchSourceProcess?

    func teardown() {
        read?.cancel()
        read = nil
        exit?.cancel()
        exit = nil
    }
}

/// Live bookkeeping for one spawned service. Only ever touched from inside the
/// Supervisor actor.
final class RunningProcess {
    let pid: pid_t
    let master: Int32
    let startedAt: Double
    let holder = SourceHolder()
    var continuation: AsyncStream<ProcessEvent>.Continuation?
    var pumpTask: Task<Void, Never>?
    var healthTask: Task<Void, Never>?
    var killTask: Task<Void, Never>?
    /// Distinguishes "we asked it to stop" from "it died on its own", which is the
    /// difference between the `stopped` and `failed` states.
    var stopRequested = false
    var reaped = false
    var sawEOF = false
    /// Whether a health probe has ever succeeded. Before the first success we cannot
    /// tell "still booting" from "broken"; after it, a failure is a real regression.
    var everHealthy = false
    var healthFailures = 0

    init(pid: pid_t, master: Int32, startedAt: Double) {
        self.pid = pid
        self.master = master
        self.startedAt = startedAt
    }
}

struct Subscriber {
    let id: UUID
    let wantsStatus: Bool
    /// Service name to follow, or "*" for all. nil means no log interest.
    let logFilter: String?
    let continuation: AsyncStream<Event>.Continuation
}

actor Supervisor {
    private var config: Config
    private var status: [String: ServiceStatus] = [:]
    private var order: [String] = []
    private var procs: [String: RunningProcess] = [:]
    private var stores: [String: LogStore] = [:]
    private var subscribers: [UUID: Subscriber] = [:]
    private var exitWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var idleFlushTask: Task<Void, Never>?

    init(config: Config) {
        // Cannot call adoptConfig() from an actor's init, and would not want to: at
        // init there is no prior state to reconcile against, which is all that
        // function exists to do.
        self.config = config
        self.order = config.services.map(\.name)
        for svc in config.services {
            stores[svc.name] = LogStore(name: svc.name, fileURL: Paths.logFile(for: svc.name))
            status[svc.name] = ServiceStatus(
                name: svc.name, state: .stopped, port: svc.port,
                health: svc.health == nil ? .none : .pending,
                command: svc.command, cwd: svc.cwd
            )
        }
    }

    // MARK: - Config

    private func adoptConfig(_ new: Config) {
        config = new
        order = new.services.map(\.name)
        for svc in new.services {
            if stores[svc.name] == nil {
                stores[svc.name] = LogStore(name: svc.name, fileURL: Paths.logFile(for: svc.name))
            }
            if var existing = status[svc.name] {
                // Keep live runtime facts, refresh the spec-derived ones.
                existing.command = svc.command
                existing.cwd = svc.cwd
                existing.port = svc.port
                status[svc.name] = existing
            } else {
                status[svc.name] = ServiceStatus(
                    name: svc.name, state: .stopped, port: svc.port,
                    health: svc.health == nil ? .none : .pending,
                    command: svc.command, cwd: svc.cwd
                )
            }
        }
        // Drop bookkeeping for services deleted from the file — unless still running,
        // in which case they stay visible so they can be stopped deliberately.
        let known = Set(order)
        for name in status.keys where !known.contains(name) {
            if procs[name] == nil {
                status.removeValue(forKey: name)
                stores.removeValue(forKey: name)
            } else if !order.contains(name) {
                order.append(name)
            }
        }
    }

    func reload() throws -> [String] {
        let new = try ConfigLoader.load()
        adoptConfig(new)
        broadcast(Event(event: .reloaded, services: snapshot()))
        return new.warnings
    }

    func warnings() -> [String] { config.warnings }

    // MARK: - Lifecycle

    /// Starts services flagged autostart, and begins the idle-flush ticker.
    func bootstrap() async {
        startIdleFlusher()
        let autos = config.services.filter(\.autostart).map(\.name)
        if !autos.isEmpty {
            _ = await start(names: autos)
        }
    }

    func snapshot() -> [ServiceStatus] {
        order.compactMap { status[$0] }
    }

    /// Returns a per-service error message for each service that failed to start.
    func start(names: [String]?) async -> [String: String] {
        var errors: [String: String] = [:]
        // If the user names something we have not seen, the likeliest explanation is
        // that they just added it to services.toml. Re-read once before complaining,
        // so editing the file and starting the service is a single step.
        if let names, names.contains(where: { config.service(named: $0) == nil }) {
            _ = try? reload()
        }
        for name in resolve(names) {
            guard let svc = config.service(named: name) else {
                errors[name] = "no such service"
                continue
            }
            if let existing = procs[name], !existing.reaped {
                continue  // already live; start is idempotent
            }
            do {
                try spawn(svc)
            } catch {
                errors[name] = "\(error)"
                var s = status[name] ?? ServiceStatus(name: name, state: .stopped)
                s.state = .failed
                s.pid = nil
                s.pgid = nil
                status[name] = s
                // Surface the reason where the user will look for it.
                if let store = stores[name] {
                    let line = store.ingest(Data("densha: \(error)\r\n".utf8))
                    line.forEach { broadcastLog(name: name, line: $0) }
                }
            }
        }
        broadcastStatus()
        return errors
    }

    private func spawn(_ svc: ResolvedService) throws {
        let child = try PTYSpawner.spawn(svc)
        let now = Date().timeIntervalSince1970
        let proc = RunningProcess(pid: child.pid, master: child.master, startedAt: now)

        let (stream, continuation) = AsyncStream<ProcessEvent>.makeStream(
            of: ProcessEvent.self, bufferingPolicy: .unbounded)
        proc.continuation = continuation

        // One serial queue for both sources keeps output and exit ordered.
        let queue = DispatchQueue(label: "densha.svc.\(svc.name)")
        let holder = proc.holder

        let readSource = DispatchSource.makeReadSource(fileDescriptor: child.master, queue: queue)
        readSource.setEventHandler { [weak proc] in
            guard let cont = proc?.continuation else { return }
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let n = read(child.master, &buffer, buffer.count)
                if n > 0 {
                    cont.yield(.output(Data(buffer[0..<n])))
                    continue
                }
                if n == 0 {
                    cont.yield(.eof)
                    holder.read?.cancel()
                    holder.read = nil
                    return
                }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    return
                default:
                    // On Darwin a pty master returns EIO once every slave fd is closed,
                    // which is this fd's version of end-of-file.
                    cont.yield(.eof)
                    holder.read?.cancel()
                    holder.read = nil
                    return
                }
            }
        }
        holder.read = readSource

        let exitSource = DispatchSource.makeProcessSource(
            identifier: child.pid, eventMask: .exit, queue: queue)
        exitSource.setEventHandler { [weak proc] in
            guard let cont = proc?.continuation else { return }
            var raw: Int32 = 0
            let waited = waitpid(child.pid, &raw, WNOHANG)
            // Drain whatever the child wrote just before dying, so no output is lost.
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let n = read(child.master, &buffer, buffer.count)
                if n > 0 { cont.yield(.output(Data(buffer[0..<n]))); continue }
                break
            }
            cont.yield(.exited(status: waited == child.pid ? raw : 0))
            holder.exit?.cancel()
            holder.exit = nil
        }
        holder.exit = exitSource

        procs[svc.name] = proc

        var s = status[svc.name] ?? ServiceStatus(name: svc.name, state: .starting)
        s.state = .starting
        s.pid = child.pid
        // SETSID guarantees the child leads its own group, so pgid == pid.
        s.pgid = child.pid
        s.port = svc.port
        s.startedAt = now
        s.exitCode = nil
        s.signal = nil
        s.health = svc.health == nil ? .none : .pending
        s.command = svc.command
        s.cwd = svc.cwd
        status[svc.name] = s

        readSource.activate()
        exitSource.activate()

        proc.pumpTask = Task { [weak self] in
            for await event in stream {
                await self?.handle(event, service: svc.name)
            }
        }

        if let health = svc.health {
            proc.healthTask = Task { [weak self] in
                await self?.runHealthLoop(service: svc.name, health: health)
            }
        } else {
            // With no probe configured, "spawned and not dead" is the best signal we
            // have, so promote out of `starting` after a moment.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                await self?.promoteIfStillStarting(svc.name, pid: child.pid)
            }
        }
    }

    private func promoteIfStillStarting(_ name: String, pid: pid_t) {
        guard let proc = procs[name], proc.pid == pid, !proc.reaped else { return }
        guard var s = status[name], s.state == .starting else { return }
        s.state = .running
        status[name] = s
        broadcastStatus()
    }

    // MARK: - Event handling

    private func handle(_ event: ProcessEvent, service name: String) {
        switch event {
        case let .output(data):
            guard let store = stores[name] else { return }
            for line in store.ingest(data) {
                broadcastLog(name: name, line: line)
            }
        case .eof:
            procs[name]?.sawEOF = true
        case let .exited(raw):
            finalize(name: name, raw: raw)
        }
    }

    private func finalize(name: String, raw: Int32) {
        guard let proc = procs[name], !proc.reaped else { return }
        proc.reaped = true
        proc.killTask?.cancel()
        proc.healthTask?.cancel()

        if let store = stores[name], let last = store.flushPending() {
            broadcastLog(name: name, line: last)
        }

        proc.holder.teardown()
        proc.continuation?.finish()
        close(proc.master)

        var s = status[name] ?? ServiceStatus(name: name, state: .stopped)
        let exited = (raw & 0x7F) == 0
        let code = (raw >> 8) & 0xFF
        let signal = raw & 0x7F

        if proc.stopRequested {
            s.state = .stopped
            s.exitCode = exited ? Int32(code) : nil
            s.signal = exited ? nil : Int32(signal)
        } else if exited, code == 0 {
            s.state = .exited
            s.exitCode = 0
            s.signal = nil
        } else {
            s.state = .failed
            s.exitCode = exited ? Int32(code) : nil
            s.signal = exited ? nil : Int32(signal)
        }
        s.pid = nil
        s.pgid = nil
        s.health = config.service(named: name)?.health == nil ? .none : .pending
        status[name] = s

        procs.removeValue(forKey: name)
        broadcastStatus()

        for waiter in exitWaiters.removeValue(forKey: name) ?? [] {
            waiter.resume()
        }
    }

    // MARK: - Stopping

    func stop(names: [String]?) async -> [String: String] {
        var errors: [String: String] = [:]
        let targets = resolve(names)
        await withTaskGroup(of: Void.self) { group in
            for name in targets {
                guard config.service(named: name) != nil || procs[name] != nil else {
                    errors[name] = "no such service"
                    continue
                }
                group.addTask { [weak self] in
                    await self?.stopOne(name)
                }
            }
        }
        broadcastStatus()
        return errors
    }

    private func stopOne(_ name: String) async {
        guard let proc = procs[name], !proc.reaped else { return }
        let timeout = config.service(named: name)?.stopTimeout ?? Defaults.stopTimeout
        // Bind pid locally: RunningProcess is not Sendable, so the escaping Task below
        // must not capture it.
        let pid = proc.pid
        proc.stopRequested = true

        if var s = status[name] {
            s.state = .stopping
            status[name] = s
            broadcastStatus()
        }

        // Signal the whole process group, not just the shell we spawned. This is the
        // difference between releasing :3000 and orphaning a node process that holds it.
        kill(-pid, SIGTERM)

        proc.killTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.forceKill(name, pid: pid)
        }

        await waitForExit(name)
    }

    private func forceKill(_ name: String, pid: pid_t) {
        // Only if this is still the same process — never signal a recycled pid.
        guard let proc = procs[name], proc.pid == pid, !proc.reaped else { return }
        kill(-pid, SIGKILL)
    }

    private func waitForExit(_ name: String) async {
        guard let proc = procs[name], !proc.reaped else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exitWaiters[name, default: []].append(continuation)
        }
    }

    func restart(names: [String]?) async -> [String: String] {
        let targets = resolve(names)
        _ = await stop(names: targets)
        // A brief pause gives the OS time to release listening sockets, so the
        // restarted process does not hit EADDRINUSE on its own port.
        let grace = targets.compactMap { config.service(named: $0)?.restartGrace }.max()
        if let grace, grace > 0 {
            try? await Task.sleep(for: .milliseconds(grace))
        }
        return await start(names: targets)
    }

    /// Stops everything, for daemon shutdown.
    func stopAll() async {
        _ = await stop(names: nil)
        idleFlushTask?.cancel()
    }

    // MARK: - Health

    private func runHealthLoop(service name: String, health: ResolvedHealth) async {
        while !Task.isCancelled {
            guard let proc = procs[name], !proc.reaped else { return }
            let pid = proc.pid
            let ok = await HealthCheck.probe(health)
            guard !Task.isCancelled else { return }
            applyHealth(name: name, pid: pid, passing: ok)
            try? await Task.sleep(for: .seconds(health.interval))
        }
    }

    /// Consecutive failed probes tolerated before a service that has never been
    /// healthy is called unhealthy rather than still starting. At the default 2s
    /// interval this is a 20s grace period — long enough for a dev server to bind,
    /// short enough that a broken one does not pulse amber forever.
    private static let healthGraceProbes = 10

    private func applyHealth(name: String, pid: pid_t, passing: Bool) {
        guard let proc = procs[name], proc.pid == pid, !proc.reaped else { return }
        guard var s = status[name], s.state != .stopping else { return }

        let newState: ServiceState
        if passing {
            proc.everHealthy = true
            proc.healthFailures = 0
            newState = .running
        } else {
            proc.healthFailures += 1
            // A service that was healthy and now is not has definitely regressed. One
            // that has never answered may simply still be booting — `expo run:ios`
            // spends a long time in a native build — so it keeps the benefit of the
            // doubt, but not indefinitely.
            newState =
                (proc.everHealthy || proc.healthFailures >= Self.healthGraceProbes)
                ? .unhealthy : .starting
        }

        let newHealth: HealthState = passing ? .passing : .failing
        guard s.health != newHealth || s.state != newState else { return }
        s.health = newHealth
        s.state = newState
        status[name] = s
        broadcastStatus()
    }

    // MARK: - Logs and input

    func logLines(name: String, tail: Int?) throws -> [LogLine] {
        guard let store = stores[name] else {
            throw DenshaError.noSuchService(name)
        }
        return store.tail(tail)
    }

    /// Writes to the service's PTY master, which is how Expo's `i`/`r`/`j` and any
    /// other interactive key reaches the process.
    func sendInput(name: String, data: String) throws {
        guard let proc = procs[name], !proc.reaped else {
            throw DenshaError.serviceNotRunning(name)
        }
        let bytes = Array(data.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { raw in
                write(proc.master, raw.baseAddress!, raw.count)
            }
            if written > 0 {
                offset += written
            } else if errno == EINTR || errno == EAGAIN {
                continue
            } else {
                throw DenshaError.daemonUnreachable(
                    "write to \(name) failed: \(String(cString: strerror(errno)))")
            }
        }
    }

    /// Pushes out partial lines that have been sitting without a newline, so prompts
    /// and progress indicators appear instead of hanging invisibly in the buffer.
    private func startIdleFlusher() {
        idleFlushTask?.cancel()
        idleFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await self?.flushPendingLines()
            }
        }
    }

    private func flushPendingLines() {
        for (name, store) in stores where procs[name] != nil {
            if let line = store.flushPending() {
                broadcastLog(name: name, line: line)
            }
        }
    }

    // MARK: - Subscriptions

    func subscribe(status wantsStatus: Bool, logFilter: String?) -> (UUID, AsyncStream<Event>) {
        let id = UUID()
        // makeStream rather than the closure-taking initialiser: that closure is
        // `sending`, so mutating actor state from inside it is a data race.
        let (stream, continuation) = AsyncStream<Event>.makeStream(
            of: Event.self, bufferingPolicy: .bufferingNewest(4096))
        subscribers[id] = Subscriber(
            id: id, wantsStatus: wantsStatus, logFilter: logFilter, continuation: continuation)
        return (id, stream)
    }

    func unsubscribe(_ id: UUID) {
        subscribers[id]?.continuation.finish()
        subscribers.removeValue(forKey: id)
    }

    private func broadcastStatus() {
        broadcast(Event(event: .status, services: snapshot()))
    }

    private func broadcast(_ event: Event) {
        for sub in subscribers.values where sub.wantsStatus {
            sub.continuation.yield(event)
        }
    }

    private func broadcastLog(name: String, line: LogLine) {
        for sub in subscribers.values {
            guard let filter = sub.logFilter, filter == name || filter == "*" else { continue }
            sub.continuation.yield(Event(event: .log, name: name, line: line))
        }
    }

    // MARK: - Helpers

    private func resolve(_ names: [String]?) -> [String] {
        guard let names, !names.isEmpty else { return order }
        return names
    }
}
