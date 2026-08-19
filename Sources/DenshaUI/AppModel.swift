import AppKit
import DenshaCore
import Observation
import SwiftUI

@MainActor
@Observable
public final class AppModel {
    public var services: [ServiceStatus] = []
    var link: LinkState = .connecting
    var warnings: [String] = []
    var lastError: String?
    var selectedLogService: String?
    var busy: Set<String> = []

    private let daemonLink = DaemonLink()
    private var consumeTask: Task<Void, Never>?

    public init() {}

    public func connect() {
        guard consumeTask == nil else { return }
        let stream = daemonLink.events()
        consumeTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .state(let state): self.link = state
                case .services(let services): self.apply(services)
                case .warnings(let warnings): self.warnings = warnings
                }
            }
        }
    }

    public func disconnect() {
        consumeTask?.cancel()
        consumeTask = nil
        daemonLink.stop()
    }

    private func apply(_ incoming: [ServiceStatus]) {
        services = incoming
        busy = busy.filter { name in
            guard let service = incoming.first(where: { $0.name == name }) else { return false }
            return service.state == .starting || service.state == .stopping
        }
    }

    public var anyLive: Bool { services.contains { $0.isLive } }
    public var anyFailed: Bool { services.contains { $0.state == .failed } }
    public var liveCount: Int { services.count(where: \.isLive) }

    public var menuBarSymbol: String {
        if anyFailed { return "tram.fill" }
        return anyLive ? "tram.fill" : "tram"
    }

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

    func reload() {
        lastError = nil
        Task {
            do {
                let response = try await Commands.run(.reload)
                apply(response.services ?? [])
                warnings = response.warnings ?? []
            } catch {
                lastError = "\(error)"
            }
        }
    }

    func send(_ keys: String, to name: String) {
        Task {
            do {
                _ = try await Commands.run(.input, name: name, data: keys)
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
                _ = try await Commands.run(op, names: names)
            } catch {
                lastError = "\(error)"
            }
            busy.subtract(
                marking.filter { name in
                    guard let service = services.first(where: { $0.name == name }) else {
                        return true
                    }
                    return service.state != .starting && service.state != .stopping
                })
        }
    }

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
