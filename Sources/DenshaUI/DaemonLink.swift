import DenshaCore
import Foundation

enum LinkState: Sendable, Equatable {
    case connecting
    case connected
    case failed(String)

    var isConnected: Bool { self == .connected }
}

enum LinkEvent: Sendable {
    case state(LinkState)
    case services([ServiceStatus])
    case warnings([String])
    case ports([ScannedPort])
}

@MainActor
protocol DaemonServing: AnyObject {
    func events() -> AsyncStream<LinkEvent>
    func run(_ command: DaemonCommand) async throws -> Response
    func stop()
}

@MainActor
final class LiveDaemonService: DaemonServing {
    private var link: DaemonLink?

    func events() -> AsyncStream<LinkEvent> {
        let link = DaemonLink()
        self.link = link
        return link.events()
    }

    func run(_ command: DaemonCommand) async throws -> Response {
        try await Commands.run(command)
    }

    func stop() {
        link?.stop()
        link = nil
    }
}

final class DaemonLink: @unchecked Sendable {
    private let lock = NSLock()
    private var stopping = false
    private var client: DaemonClient?

    func events() -> AsyncStream<LinkEvent> {
        let (stream, continuation) = AsyncStream<LinkEvent>.makeStream(
            of: LinkEvent.self, bufferingPolicy: .bufferingNewest(256))

        let thread = Thread { [weak self] in
            self?.loop(continuation)
        }
        thread.name = "densha.link"
        thread.stackSize = 512 * 1024
        thread.start()

        continuation.onTermination = { [weak self] _ in
            self?.stop()
        }
        return stream
    }

    private func loop(_ continuation: AsyncStream<LinkEvent>.Continuation) {
        var backoff: Double = 0.25

        while !isStopping {
            continuation.yield(.state(.connecting))
            do {
                let client = try DaemonClient.connect()
                setClient(client)

                let response = try client.send(.watch)
                continuation.yield(.state(.connected))
                continuation.yield(.services(response.services ?? []))
                continuation.yield(.warnings(response.warnings ?? []))
                continuation.yield(.ports(response.ports ?? []))
                backoff = 0.25

                while !isStopping, let message = try client.nextMessage() {
                    switch message {
                    case .event(let event):
                        switch try event.decoded() {
                        case .status(let services):
                            continuation.yield(.services(services))
                        case .reloaded(let services, let warnings):
                            continuation.yield(.services(services))
                            continuation.yield(.warnings(warnings))
                        case .ports(let ports):
                            continuation.yield(.ports(ports))
                        case .log:
                            continue
                        }
                    case .response:
                        continue
                    }
                }
                setClient(nil)
                guard !isStopping else { break }
                continuation.yield(.state(.failed("denshad closed the connection")))
            } catch {
                setClient(nil)
                guard !isStopping else { break }
                continuation.yield(.state(.failed("\(error)")))
            }

            let deadline = Date().addingTimeInterval(backoff)
            while !isStopping, Date() < deadline {
                usleep(50_000)
            }
            backoff = min(backoff * 2, 5)
        }
        continuation.finish()
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func setClient(_ new: DaemonClient?) {
        lock.lock()
        client = new
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopping = true
        let current = client
        client = nil
        lock.unlock()
        current?.close()
    }
}

enum Commands {
    static func run(_ command: DaemonCommand) async throws -> Response {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Response, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let client = try DaemonClient.connect()
                    defer { client.close() }
                    let response = try client.send(command)
                    if !response.ok {
                        throw DenshaError.commandFailed(response.error ?? "command failed")
                    }
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
