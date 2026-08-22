import DenshaCore
import Foundation
import Synchronization

enum LinkState: Sendable, Equatable {
    case connecting
    case connected
    case failed(String)
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

    func stop() {
        link?.stop()
        link = nil
    }
}

/// Tracks a stop flag plus the client to interrupt, shared by the watch and log threads.
final class ConnectionControl: Sendable {
    private let state = Mutex<(stopping: Bool, client: DaemonClient?)>((false, nil))

    var isStopping: Bool {
        state.withLock { $0.stopping }
    }

    func set(_ client: DaemonClient?) {
        state.withLock { $0.client = client }
    }

    func stop() {
        state.withLock { state in
            state.stopping = true
            state.client?.close()
            state.client = nil
        }
    }
}

final class DaemonLink: Sendable {
    private let control = ConnectionControl()

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

        while !control.isStopping {
            continuation.yield(.state(.connecting))
            do {
                let client = try DaemonClient.connect()
                control.set(client)

                let response = try client.send(.watch)
                continuation.yield(.state(.connected))
                continuation.yield(.services(response.services ?? []))
                continuation.yield(.warnings(response.warnings ?? []))
                continuation.yield(.ports(response.ports ?? []))
                backoff = 0.25

                while !control.isStopping, let message = try client.nextMessage() {
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
                control.set(nil)
                guard !control.isStopping else { break }
                continuation.yield(.state(.failed("denshad closed the connection")))
            } catch {
                control.set(nil)
                guard !control.isStopping else { break }
                continuation.yield(.state(.failed("\(error)")))
            }

            let deadline = Date().addingTimeInterval(backoff)
            while !control.isStopping, Date() < deadline {
                usleep(50_000)
            }
            backoff = min(backoff * 2, 5)
        }
        continuation.finish()
    }

    func stop() {
        control.stop()
    }
}
