import DenshaCore
import Foundation
import Observation

private let projectPage = URL(string: "https://github.com/masmeert/densha")!

@MainActor
@Observable
public final class AppModel {
    public var services: [ServiceStatus] = []
    var scannedPorts: [ScannedPort] = []
    var link: LinkState = .connecting
    var warnings: [String] = []
    var lastError: String?
    var selectedLogService: String?
    var busy: Set<String> = []
    var killingPorts: Set<Int> = []
    var serviceEditor: ServiceEditorRequest?

    private let daemon: any DaemonServing
    private let applicationActions: any ApplicationActions
    private let configFile: URL
    private var consumeTask: Task<Void, Never>?

    public convenience init() {
        self.init(daemon: LiveDaemonService(), applicationActions: MacApplicationActions())
    }

    init(
        daemon: any DaemonServing, applicationActions: any ApplicationActions,
        configFile: URL = Paths.configFile
    ) {
        self.daemon = daemon
        self.applicationActions = applicationActions
        self.configFile = configFile
    }

    public func connect() {
        guard consumeTask == nil else { return }
        let stream = daemon.events()
        consumeTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .state(let state): self.link = state
                case .services(let services): self.apply(services)
                case .warnings(let warnings): self.warnings = warnings
                case .ports(let ports): self.scannedPorts = ports
                }
            }
        }
    }

    public func disconnect() {
        consumeTask?.cancel()
        consumeTask = nil
        daemon.stop()
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

    public var menuBarSymbol: String { (anyFailed || anyLive) ? "tram.fill" : "tram" }

    func toggle(_ service: ServiceStatus) {
        service.isLive ? stop(service.name) : start(service.name)
    }

    func start(_ name: String) { perform(.start(names: [name]), marking: [name]) }
    func stop(_ name: String) { perform(.stop(names: [name]), marking: [name]) }
    func restart(_ name: String) { perform(.restart(names: [name]), marking: [name]) }

    struct ServiceGroup: Identifiable {
        let project: String?
        let services: [ServiceStatus]

        var id: String { project ?? "" }
        var anyLive: Bool { services.contains(where: \.isLive) }
        var allLive: Bool { services.allSatisfy(\.isLive) }
    }

    var groups: [ServiceGroup] {
        var projects: [String?] = []
        var members: [String: [ServiceStatus]] = [:]
        for service in services {
            let key = service.project ?? ""
            if members[key] == nil { projects.append(service.project) }
            members[key, default: []].append(service)
        }
        return projects.map { ServiceGroup(project: $0, services: members[$0 ?? ""] ?? []) }
    }

    func start(_ group: ServiceGroup) {
        let names = group.services.filter { !$0.isLive }.map(\.name)
        guard !names.isEmpty else { return }
        perform(.start(names: group.project.map { [$0] } ?? names), marking: names)
    }

    func stop(_ group: ServiceGroup) {
        let names = group.services.filter(\.isLive).map(\.name)
        guard !names.isEmpty else { return }
        perform(.stop(names: names), marking: names)
    }

    func restart(_ group: ServiceGroup) {
        let names = group.services.filter(\.isLive).map(\.name)
        guard !names.isEmpty else { return }
        perform(.restart(names: names), marking: names)
    }

    func stopAll() {
        let names = services.filter(\.isLive).map(\.name)
        guard !names.isEmpty else { return }
        perform(.stop(names: names), marking: names)
    }

    func reload() {
        lastError = nil
        Task {
            do {
                let response = try await daemon.run(.reload)
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
                _ = try await daemon.run(.input(name: name, data: keys))
            } catch {
                lastError = "\(error)"
            }
        }
    }

    private func perform(_ command: DaemonCommand, marking: [String]) {
        lastError = nil
        busy.formUnion(marking)
        Task {
            do {
                _ = try await daemon.run(command)
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

    func kill(_ scanned: ScannedPort) {
        lastError = nil
        killingPorts.insert(scanned.port)
        Task {
            do {
                let response = try await daemon.run(.kill(port: scanned.port))
                if let ports = response.ports { scannedPorts = ports }
            } catch {
                lastError = "\(error)"
            }
            killingPorts.remove(scanned.port)
        }
    }

    func openInBrowser(_ scanned: ScannedPort) {
        guard let url = URL(string: "http://localhost:\(scanned.port)") else { return }
        applicationActions.open(url)
    }

    func openProjectPage() {
        applicationActions.open(projectPage)
    }

    func revealInFinder(_ service: ServiceStatus) {
        applicationActions.revealInFinder(path: service.cwd)
    }

    func copyToClipboard(_ text: String) {
        applicationActions.copyToClipboard(text)
    }

    func saveLogFile(for service: String) {
        do {
            try applicationActions.saveLogFile(for: service)
        } catch {
            lastError = "\(error)"
        }
    }

    struct ServiceEditorRequest: Identifiable {
        let id = UUID()
        var editing: String?
        var project: String?
        var folder: String?
        var newProject: String?
        var service: ServiceDraft?
    }

    var projectNames: [String] { groups.compactMap(\.project) }

    func requestNewService(project: String? = nil) {
        let folder = project.flatMap { name in
            (try? ConfigDocument.load(from: configFile))?.cwd(ofProject: name)
        }
        serviceEditor = ServiceEditorRequest(project: project, folder: folder)
    }

    func requestNewService(adopting scanned: ScannedPort) {
        let detected = ProjectFolder.inspect(pid: scanned.pid)
        var request = ServiceEditorRequest(
            folder: detected?.path,
            service: ServiceDraft(
                name: "web", command: detected?.command ?? "", port: scanned.port))
        if let project = detected?.projectName, !project.isEmpty {
            if projectNames.contains(project) {
                request.project = project
            } else {
                request.newProject = project
            }
        }
        serviceEditor = request
    }

    func requestEdit(_ service: ServiceStatus) {
        let configured = try? ConfigLoader.load(from: configFile).service(named: service.name)
        serviceEditor = ServiceEditorRequest(
            editing: service.name,
            project: service.project,
            folder: ConfigLoader.abbreviateTilde(configured?.cwd ?? service.cwd),
            service: ServiceDraft(
                name: service.shortName,
                command: configured?.command ?? service.command,
                port: configured?.port ?? service.port,
                autostart: configured?.autostart ?? false,
                health: configured?.health.map {
                    HealthDraft(kind: $0.kind, port: $0.port, path: $0.path)
                }
            )
        )
    }

    func inspectFolder(startingAt folder: String?) -> ProjectFolder? {
        guard let url = applicationActions.chooseFolder(startingAt: folder) else { return nil }
        return ProjectFolder.inspect(url)
    }

    func save(
        _ service: ServiceDraft, project: String?, folder: String, replacing: String? = nil
    ) throws {
        var document = try ConfigDocument.load(from: configFile)
        let named = project?.trimmingCharacters(in: .whitespaces)
        let project = (named?.isEmpty ?? true) ? nil : named
        var draft = service

        if let replacing, ServiceName.project(of: replacing) == project {
            draft.cwd = cwd(for: project, folder: folder, in: document)
            try document.replace(draft, named: replacing)
        } else {
            if let replacing { try document.remove(serviceNamed: replacing) }
            if let project, !document.hasProject(named: project) {
                draft.cwd = nil
                try document.add(ProjectDraft(name: project, cwd: folder, services: [draft]))
            } else {
                draft.cwd = cwd(for: project, folder: folder, in: document)
                try document.add(draft, toProject: project)
            }
        }

        try document.save(to: configFile)
        serviceEditor = nil
        reload()
    }

    private func cwd(for project: String?, folder: String, in document: ConfigDocument) -> String? {
        guard let project else { return folder }
        return isSameDirectory(document.cwd(ofProject: project), folder) ? nil : folder
    }

    private func isSameDirectory(_ one: String?, _ other: String?) -> Bool {
        guard let one, let other else { return false }
        return URL(fileURLWithPath: ConfigLoader.expandTilde(one)).standardizedFileURL.path
            == URL(fileURLWithPath: ConfigLoader.expandTilde(other)).standardizedFileURL.path
    }

    func openConfigInEditor() {
        do {
            try applicationActions.openConfig()
        } catch {
            lastError = "\(error)"
        }
    }
}
