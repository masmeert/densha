import DenshaCore
import Observation
import SwiftUI

@MainActor
@Observable
class LogFollower {
    let service: String
    var lines: [LogLine] = []
    var failure: String?

    private let maxLines = 5000
    private var thread: Thread?
    private let control = Control()

    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var stopping = false
        private var client: DaemonClient?

        var isStopping: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopping
        }
        func set(_ c: DaemonClient?) {
            lock.lock()
            client = c
            lock.unlock()
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

    private static var isRunningForPreviews: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    func start() {
        guard thread == nil else { return }
        if Self.isRunningForPreviews {
            #if DEBUG
                lines = Sample.logLines
            #endif
            return
        }
        let service = service
        let control = control
        let thread = Thread { [weak self] in
            do {
                let client = try DaemonClient.connect()
                control.set(client)
                let response = try client.send(.logs(name: service, tail: 2000, follow: true))
                guard response.ok else {
                    let message = response.error ?? "could not read logs"
                    Task { @MainActor in self?.failure = message }
                    return
                }
                let initial = response.lines ?? []
                Task { @MainActor in self?.append(initial) }

                while !control.isStopping, let message = try client.nextMessage() {
                    if case .event(let event) = message,
                        case .log(_, let line) = try event.decoded()
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
        let known = lines.last?.seq
        let fresh = known.map { last in incoming.filter { $0.seq > last } } ?? incoming
        guard !fresh.isEmpty else { return }
        lines.append(contentsOf: fresh)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }
}
