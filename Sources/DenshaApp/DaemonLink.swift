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
}

/// Holds the app's long-lived `watch` connection to the daemon and reconnects on its
/// own if the daemon is restarted or upgraded underneath us.
///
/// Reads block, so the loop lives on a dedicated Thread rather than the cooperative
/// pool — parking a pool thread indefinitely could starve unrelated work.
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
                // Spawns a daemon if none is up, so simply launching the app is enough
                // to bring the stack's supervisor back.
                let client = try DaemonClient.connect()
                setClient(client)

                let response = try client.send(.watch)
                continuation.yield(.state(.connected))
                continuation.yield(.services(response.services ?? []))
                continuation.yield(.warnings(response.warnings ?? []))
                backoff = 0.25

                while !isStopping, let message = try client.nextMessage() {
                    switch message {
                    case let .event(event):
                        if let services = event.services {
                            continuation.yield(.services(services))
                        }
                    case .response:
                        // Commands go out on their own short-lived connections, so a
                        // reply here is unexpected; ignoring it keeps the stream alive.
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

            // Back off so a daemon that refuses to start does not become a spin loop.
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
        // Closing under the reader unblocks it so the loop can notice `stopping`.
        current?.close()
    }
}

/// One-shot commands. Each runs on its own connection so it can never race the
/// persistent watch reader for a response.
enum Commands {
    static func run(
        _ op: Op, names: [String]? = nil, name: String? = nil, data: String? = nil
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let client = try DaemonClient.connect()
                    defer { client.close() }
                    let response = try client.send(op, names: names, name: name, data: data)
                    if !response.ok {
                        throw DenshaError.daemonUnreachable(response.error ?? "command failed")
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
