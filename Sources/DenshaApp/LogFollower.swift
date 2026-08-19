import DenshaCore
import SwiftUI

/// Streams one service's output for the log window. A separate connection per
/// followed service keeps this independent of the panel's status link.
@MainActor
@Observable
final class LogFollower {
    let service: String
    var lines: [LogLine] = []
    var failure: String?

    /// Matches the daemon's own ring size, so scrolling back in the window shows
    /// everything the daemon still remembers and nothing it does not.
    private let maxLines = 5000
    private var thread: Thread?
    private let control = Control()

    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var stopping = false
        private var client: DaemonClient?

        var isStopping: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopping
        }
        func set(_ c: DaemonClient?) {
            lock.lock(); client = c; lock.unlock()
        }
        func stop() {
            lock.lock()
            stopping = true
            let c = client
            client = nil
            lock.unlock()
            c?.close()
        }
    }

    init(service: String) {
        self.service = service
    }

    func start() {
        guard thread == nil else { return }
        let service = service
        let control = control
        let thread = Thread { [weak self] in
            do {
                let client = try DaemonClient.connect()
                control.set(client)
                let response = try client.send(.logs, name: service, tail: 2000, follow: true)
                guard response.ok else {
                    let message = response.error ?? "could not read logs"
                    Task { @MainActor in self?.failure = message }
                    return
                }
                let initial = response.lines ?? []
                Task { @MainActor in self?.append(initial) }

                while !control.isStopping, let message = try client.nextMessage() {
                    if case let .event(event) = message, event.event == .log,
                        let line = event.line
                    {
                        Task { @MainActor in self?.append([line]) }
                    }
                }
            } catch {
                guard !control.isStopping else { return }
                Task { @MainActor in self?.failure = "\(error)" }
            }
        }
        thread.name = "densha.logs.\(service)"
        thread.start()
        self.thread = thread
    }

    func stop() {
        control.stop()
        thread = nil
    }

    func clear() {
        lines.removeAll()
    }

    private func append(_ incoming: [LogLine]) {
        guard !incoming.isEmpty else { return }
        // The daemon replays a tail on connect, which can overlap lines already shown.
        let known = lines.last?.seq
        let fresh = known.map { last in incoming.filter { $0.seq > last } } ?? incoming
        guard !fresh.isEmpty else { return }
        lines.append(contentsOf: fresh)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }
}
