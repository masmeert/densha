import Darwin
import DenshaCore
import Foundation

enum ProcessEvent: Sendable {
    case output(Data)
    case eof
    case exited(status: Int32)
}

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

final class RunningProcess {
    let pid: pid_t
    let master: Int32
    let startedAt: Double
    let holder = SourceHolder()
    var continuation: AsyncStream<ProcessEvent>.Continuation?
    var pumpTask: Task<Void, Never>?
    var healthTask: Task<Void, Never>?
    var killTask: Task<Void, Never>?
    var stopRequested = false
    var reaped = false
    var sawEOF = false
    var everHealthy = false
    var healthFailures = 0

    init(pid: pid_t, master: Int32, startedAt: Double) {
        self.pid = pid
        self.master = master
        self.startedAt = startedAt
    }
}

actor Supervisor {
    private var config: Config
    private var status: [String: ServiceStatus] = [:]
    private var order: [String] = []
    private var procs: [String: RunningProcess] = [:]
    private var stores: [String: LogStore] = [:]
    private var eventBroker = EventBroker()
    private var exitWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var idleFlushTask: Task<Void, Never>?

    init(config: Config) {
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

    private func adoptConfig(_ new: Config) {
        config = new
        order = new.services.map(\.name)
        for svc in new.services {
            if stores[svc.name] == nil {
                stores[svc.name] = LogStore(name: svc.name, fileURL: Paths.logFile(for: svc.name))
            }
            if var existing = status[svc.name] {
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
        broadcast(.reloaded(services: snapshot(), warnings: new.warnings))
        return new.warnings
    }

    func warnings() -> [String] { config.warnings }

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

    func start(names: [String]?) async -> [String: String] {
        var errors: [String: String] = [:]
        if let names, names.contains(where: { config.service(named: $0) == nil }) {
            _ = try? reload()
        }
        for name in resolve(names) {
            guard let svc = config.service(named: name) else {
                errors[name] = "no such service"
                continue
            }
            if let existing = procs[name], !existing.reaped {
                continue
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
                if let store = stores[name] {
                    let line = store.ingest(Data("densha: \(error)\r\n".utf8))
                    for entry in line { broadcastLog(name: name, line: entry) }
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
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let n = read(child.master, &buffer, buffer.count)
                if n > 0 {
                    cont.yield(.output(Data(buffer[0..<n])))
                    continue
                }
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

    private func handle(_ event: ProcessEvent, service name: String) {
        switch event {
        case .output(let data):
            guard let store = stores[name] else { return }
            for line in store.ingest(data) {
                broadcastLog(name: name, line: line)
            }
        case .eof:
            procs[name]?.sawEOF = true
        case .exited(let raw):
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
        let pid = proc.pid
        proc.stopRequested = true

        if var s = status[name] {
            s.state = .stopping
            status[name] = s
            broadcastStatus()
        }

        kill(-pid, SIGTERM)

        proc.killTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.forceKill(name, pid: pid)
        }

        await waitForExit(name)
    }

    private func forceKill(_ name: String, pid: pid_t) {
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
        let grace = targets.compactMap { config.service(named: $0)?.restartGrace }.max()
        if let grace, grace > 0 {
            try? await Task.sleep(for: .milliseconds(grace))
        }
        return await start(names: targets)
    }

    func stopAll() async {
        _ = await stop(names: nil)
        idleFlushTask?.cancel()
    }

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

    func logLines(name: String, tail: Int?) throws -> [LogLine] {
        guard let store = stores[name] else {
            throw DenshaError.noSuchService(name)
        }
        return store.tail(tail)
    }

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

    func subscribe(status wantsStatus: Bool, logFilter: String?) -> (UUID, AsyncStream<DaemonEvent>)
    {
        eventBroker.subscribe(status: wantsStatus, logFilter: logFilter)
    }

    func unsubscribe(_ id: UUID) {
        eventBroker.unsubscribe(id)
    }

    private func broadcastStatus() {
        broadcast(.status(snapshot()))
    }

    private func broadcast(_ event: DaemonEvent) {
        eventBroker.broadcast(event)
    }

    private func broadcastLog(name: String, line: LogLine) {
        eventBroker.broadcastLog(name: name, line: line)
    }

    private func resolve(_ names: [String]?) -> [String] {
        guard let names, !names.isEmpty else { return order }
        return names
    }
}
