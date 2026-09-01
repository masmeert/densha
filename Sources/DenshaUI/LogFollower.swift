import DenshaCore
import Observation
import SwiftUI
import Synchronization

@MainActor
@Observable
class LogFollower {
    let service: String
    var lines: [LogLine] = []
    var failure: String?

    private let maxLines = 5000
    private var thread: Thread?
    private var drainTask: Task<Void, Never>?
    private let pending = Mutex<[LogLine]>([])
    private let control = ConnectionControl()

    init(service: String) {
        self.service = service
    }

    #if DEBUG
        private static var isRunningForPreviews: Bool {
            ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        }
    #endif

    func start() {
        guard thread == nil else { return }
        #if DEBUG
            if Self.isRunningForPreviews {
                lines = Sample.logLines
                return
            }
        #endif
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
                self?.enqueue(response.lines ?? [])

                while !control.isStopping, let message = try client.nextMessage() {
                    if case .event(let event) = message,
                        case .log(_, let line) = try event.decoded()
                    {
                        self?.enqueue([line])
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
        drainTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.drain()
            }
        }
    }

    func stop() {
        control.stop()
        drainTask?.cancel()
        drainTask = nil
        thread = nil
    }

    func clear() {
        pending.withLock { $0.removeAll() }
        lines.removeAll()
    }

    /// Called from the reader thread: buffer instead of hopping to the main
    /// actor per line, a chatty service floods the UI otherwise.
    private nonisolated func enqueue(_ incoming: [LogLine]) {
        pending.withLock {
            $0.append(contentsOf: incoming)
            if $0.count > maxLines { $0.removeFirst($0.count - maxLines) }
        }
    }

    private func drain() {
        let batch = pending.withLock { buffer -> [LogLine] in
            defer { buffer.removeAll(keepingCapacity: true) }
            return buffer
        }
        append(batch)
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
