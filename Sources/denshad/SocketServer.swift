import Darwin
import DenshaCore
import Foundation

/// Single-instance guard. Two clients racing to lazily spawn a daemon is normal, so
/// exactly one must win and the other must exit quietly.
final class InstanceLock {
    private var fd: Int32

    init?(path: URL) {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(path.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        // LOCK_NB: fail immediately rather than queueing behind the running daemon.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            fd = -1
            return nil
        }
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
    }

    deinit {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }
}

/// One client connection. Responses come from the request loop and pushed events come
/// from a subscription task, so writes are serialised with a lock.
final class Connection: @unchecked Sendable {
    let socket: UnixSocket
    private let writeLock = NSLock()
    private let ioQueue: DispatchQueue
    private var closed = false

    init(socket: UnixSocket, label: String) {
        self.socket = socket
        self.ioQueue = DispatchQueue(label: "densha.conn.\(label)")
    }

    func send<T: Encodable & Sendable>(_ message: T) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        do {
            try socket.write(Wire.line(message))
        } catch {
            // Peer went away mid-write; stop trying.
            closed = true
        }
    }

    /// Blocking readLine, moved off the cooperative pool onto this connection's own
    /// serial queue. Connection counts are tiny (a menubar app plus the odd CLI call),
    /// so a parked thread per connection is cheaper than a non-blocking rewrite.
    func readLine() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [socket] in
                do {
                    continuation.resume(returning: try socket.readLine())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        writeLock.lock()
        closed = true
        writeLock.unlock()
        socket.close()
    }
}

actor SocketServer {
    private let supervisor: Supervisor
    private let path: String
    private var listener: UnixSocket?
    private var acceptTask: Task<Void, Never>?
    private var connectionCounter = 0

    init(supervisor: Supervisor, path: String) {
        self.supervisor = supervisor
        self.path = path
    }

    func start() throws {
        let listener = try UnixSocket.listen(at: path)
        self.listener = listener
        acceptTask = Task { [weak self] in
            await self?.acceptLoop(listener)
        }
    }

    func stop() {
        acceptTask?.cancel()
        listener?.close()
        listener = nil
        unlink(path)
    }

    private func acceptLoop(_ listener: UnixSocket) async {
        while !Task.isCancelled {
            let accepted: UnixSocket?
            do {
                accepted = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<UnixSocket, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            continuation.resume(returning: try listener.accept())
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } catch {
                // The listener was closed under us, which is how shutdown unblocks this.
                return
            }
            guard let socket = accepted else { return }
            connectionCounter += 1
            let connection = Connection(socket: socket, label: "\(connectionCounter)")
            Task { [weak self] in
                await self?.serve(connection)
            }
        }
    }

    private func serve(_ connection: Connection) async {
        var subscriptions: [UUID] = []
        defer {
            for id in subscriptions {
                Task { [supervisor] in await supervisor.unsubscribe(id) }
            }
            connection.close()
        }

        while true {
            let line: Data?
            do {
                line = try await connection.readLine()
            } catch {
                return
            }
            guard let line, !line.isEmpty else {
                if line == nil { return }
                continue
            }

            let request: Request
            do {
                request = try Wire.decoder.decode(Request.self, from: line)
            } catch {
                // id is unknown at this point, so 0 stands in for "unparseable".
                connection.send(Response.failure(id: 0, "bad request: \(error)"))
                continue
            }

            if let id = await handle(request, on: connection) {
                subscriptions.append(id)
            }
        }
    }

    /// Returns a subscription id when the request set up a long-lived stream.
    private func handle(_ request: Request, on connection: Connection) async -> UUID? {
        switch request.op {
        case .ping:
            connection.send(Response(id: request.id, ok: true))

        case .status:
            connection.send(
                Response(
                    id: request.id, ok: true, services: await supervisor.snapshot(),
                    warnings: await supervisor.warnings()))

        case .start:
            let errors = await supervisor.start(names: request.names)
            connection.send(response(request.id, errors, await supervisor.snapshot()))

        case .stop:
            let errors = await supervisor.stop(names: request.names)
            connection.send(response(request.id, errors, await supervisor.snapshot()))

        case .restart:
            let errors = await supervisor.restart(names: request.names)
            connection.send(response(request.id, errors, await supervisor.snapshot()))

        case .reload:
            do {
                let warnings = try await supervisor.reload()
                connection.send(
                    Response(
                        id: request.id, ok: true, services: await supervisor.snapshot(),
                        warnings: warnings))
            } catch {
                connection.send(Response.failure(id: request.id, "\(error)"))
            }

        case .input:
            guard let name = request.name, let data = request.data else {
                connection.send(
                    Response.failure(id: request.id, "input requires \"name\" and \"data\""))
                return nil
            }
            do {
                try await supervisor.sendInput(name: name, data: data)
                connection.send(Response(id: request.id, ok: true))
            } catch {
                connection.send(Response.failure(id: request.id, "\(error)"))
            }

        case .logs:
            guard let name = request.name else {
                connection.send(Response.failure(id: request.id, "logs requires \"name\""))
                return nil
            }
            do {
                let lines = try await supervisor.logLines(name: name, tail: request.tail)
                connection.send(Response(id: request.id, ok: true, lines: lines))
                guard request.follow == true else { return nil }
                let (id, stream) = await supervisor.subscribe(status: false, logFilter: name)
                pump(stream, to: connection)
                return id
            } catch {
                connection.send(Response.failure(id: request.id, "\(error)"))
            }

        case .watch:
            connection.send(Response(id: request.id, ok: true, services: await supervisor.snapshot()))
            let (id, stream) = await supervisor.subscribe(status: true, logFilter: nil)
            pump(stream, to: connection)
            return id

        case .shutdown:
            connection.send(Response(id: request.id, ok: true))
            Task { [supervisor] in
                await supervisor.stopAll()
                // Give the reply a moment to reach the client before the process goes.
                try? await Task.sleep(for: .milliseconds(150))
                exit(0)
            }
        }
        return nil
    }

    private func pump(_ stream: AsyncStream<Event>, to connection: Connection) {
        Task {
            for await event in stream {
                connection.send(event)
            }
        }
    }

    private func response(_ id: Int, _ errors: [String: String], _ services: [ServiceStatus])
        -> Response
    {
        guard !errors.isEmpty else {
            return Response(id: id, ok: true, services: services)
        }
        let detail = errors.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            .joined(separator: "; ")
        return Response(id: id, ok: false, error: detail, services: services)
    }
}
