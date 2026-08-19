import AppKit
import DenshaCore
import SwiftUI

@MainActor
@Observable
final class AppModel {
    var services: [ServiceStatus] = []
    var link: LinkState = .connecting
    var warnings: [String] = []
    /// Last command failure, shown inline in the panel until the next action.
    var lastError: String?
    /// Which service the log window is showing.
    var selectedLogService: String?
    /// Services with an in-flight command. Rendered immediately so a click always
    /// produces visible feedback, even before the daemon reports the new state.
    var busy: Set<String> = []

    private let daemonLink = DaemonLink()
    private var consumeTask: Task<Void, Never>?

    func connect() {
        guard consumeTask == nil else { return }
        let stream = daemonLink.events()
        consumeTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case let .state(state): self.link = state
                case let .services(services): self.apply(services)
                case let .warnings(warnings): self.warnings = warnings
                }
            }
        }
    }

    func disconnect() {
        consumeTask?.cancel()
        consumeTask = nil
        daemonLink.stop()
    }

    private func apply(_ incoming: [ServiceStatus]) {
        services = incoming
        // Any service whose state has settled is no longer pending.
        busy = busy.filter { name in
            guard let service = incoming.first(where: { $0.name == name }) else { return false }
            return service.state == .starting || service.state == .stopping
        }
    }

    // MARK: - Derived

    var anyLive: Bool { services.contains { $0.isLive } }
    var anyFailed: Bool { services.contains { $0.state == .failed } }
    var liveCount: Int { services.count(where: \.isLive) }

    var menuBarSymbol: String {
        if anyFailed { return "tram.fill" }
        return anyLive ? "tram.fill" : "tram"
    }

    // MARK: - Actions

    func toggle(_ service: ServiceStatus) {
        service.isLive ? stop(service.name) : start(service.name)
    }

    func start(_ name: String) { perform(.start, names: [name], marking: [name]) }
    func stop(_ name: String) { perform(.stop, names: [name], marking: [name]) }
    func restart(_ name: String) { perform(.restart, names: [name], marking: [name]) }

    func startAll() {
        let names = services.filter { !$0.isLive }.map(\.name)
        guard !names.isEmpty else { return }
        perform(.start, names: names, marking: names)
    }

    func stopAll() {
        let names = services.filter(\.isLive).map(\.name)
        guard !names.isEmpty else { return }
        perform(.stop, names: names, marking: names)
    }

    func reload() { perform(.reload, names: nil, marking: []) }

    func send(_ keys: String, to name: String) {
        Task {
            do {
                try await Commands.run(.input, name: name, data: keys)
            } catch {
                lastError = "\(error)"
            }
        }
    }

    private func perform(_ op: Op, names: [String]?, marking: [String]) {
        lastError = nil
        busy.formUnion(marking)
        Task {
            do {
                try await Commands.run(op, names: names)
            } catch {
                lastError = "\(error)"
            }
            // Clear optimistically-marked names that never reached a pending state
            // (a start that failed outright, for instance).
            busy.subtract(
                marking.filter { name in
                    guard let service = services.first(where: { $0.name == name }) else { return true }
                    return service.state != .starting && service.state != .stopping
                })
        }
    }

    // MARK: - Shell integration

    func revealInFinder(_ service: ServiceStatus) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: service.cwd)
    }

    func openConfigInEditor() {
        let url = Paths.configFile
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Paths.createDirectories()
            try? Template.starter.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
}
