import Darwin
import DenshaCore
import Foundation

final class InstanceLock {
    private var fd: Int32

    init?(path: URL) {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(path.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
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
            closed = true
        }
    }

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
                connection.send(Response.failure(id: 0, "bad request: \(error)"))
                continue
            }

            let command: DaemonCommand
            do {
                command = try request.command()
            } catch {
                connection.send(Response.failure(id: request.id, "bad request: \(error)"))
                continue
            }

            if let id = await handle(command, requestID: request.id, on: connection) {
                subscriptions.append(id)
            }
        }
    }

    private func handle(_ command: DaemonCommand, requestID: Int, on connection: Connection) async
        -> UUID?
    {
        switch command {
        case .ping:
            connection.send(Response(id: requestID, ok: true))

        case .status:
            connection.send(
                Response(
                    id: requestID, ok: true, services: await supervisor.snapshot(),
                    warnings: await supervisor.warnings()))

        case .start(let names):
            let errors = await supervisor.start(names: names)
            connection.send(response(requestID, errors, await supervisor.snapshot()))

        case .stop(let names):
            let errors = await supervisor.stop(names: names)
            connection.send(response(requestID, errors, await supervisor.snapshot()))

        case .restart(let names):
            let errors = await supervisor.restart(names: names)
            connection.send(response(requestID, errors, await supervisor.snapshot()))

        case .reload:
            do {
                let warnings = try await supervisor.reload()
                connection.send(
                    Response(
                        id: requestID, ok: true, services: await supervisor.snapshot(),
                        warnings: warnings))
            } catch {
                connection.send(Response.failure(id: requestID, "\(error)"))
            }

        case .input(let name, let data):
            do {
                try await supervisor.sendInput(name: name, data: data)
                connection.send(Response(id: requestID, ok: true))
            } catch {
                connection.send(Response.failure(id: requestID, "\(error)"))
            }

        case .logs(let name, let tail, let follow):
            do {
                let lines = try await supervisor.logLines(name: name, tail: tail)
                connection.send(Response(id: requestID, ok: true, lines: lines))
                guard follow else { return nil }
                let (id, stream) = await supervisor.subscribe(status: false, logFilter: name)
                pump(stream, to: connection)
                return id
            } catch {
                connection.send(Response.failure(id: requestID, "\(error)"))
            }

        case .watch:
            connection.send(
                Response(
                    id: requestID, ok: true, services: await supervisor.snapshot(),
                    warnings: await supervisor.warnings()))
            let (id, stream) = await supervisor.subscribe(status: true, logFilter: nil)
            pump(stream, to: connection)
            return id

        case .shutdown:
            connection.send(Response(id: requestID, ok: true))
            Task { [supervisor] in
                await supervisor.stopAll()
                try? await Task.sleep(for: .milliseconds(150))
                exit(0)
            }
        }
        return nil
    }

    private func pump(_ stream: AsyncStream<DaemonEvent>, to connection: Connection) {
        Task {
            for await event in stream {
                connection.send(Event(event))
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
