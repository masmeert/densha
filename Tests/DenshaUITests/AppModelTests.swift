import DenshaCore
import Foundation
import Testing

@testable import DenshaUI

@MainActor
@Suite("AppModel")
struct AppModelTests {
    @Test("daemon events update presentation state")
    func daemonEventsUpdatePresentationState() async {
        let daemon = FakeDaemonService()
        let model = AppModel(daemon: daemon, applicationActions: FakeApplicationActions())
        let service = ServiceStatus(name: "web", state: .running)

        model.connect()
        daemon.continuation.yield(.state(.connected))
        daemon.continuation.yield(.services([service]))
        await settle()

        #expect(model.link == .connected)
        #expect(model.services == [service])
    }

    @Test("the project page opens in the browser")
    func projectPageOpens() async {
        let actions = FakeApplicationActions()
        let model = AppModel(daemon: FakeDaemonService(), applicationActions: actions)

        model.openProjectPage()

        #expect(
            actions.openedURLs.map(\.absoluteString) == ["https://github.com/masmeert/densha"])
    }

    @Test("scanned ports arrive from the daemon and open in the browser")
    func scannedPortsAreShownAndOpened() async {
        let daemon = FakeDaemonService()
        let actions = FakeApplicationActions()
        let model = AppModel(daemon: daemon, applicationActions: actions)
        let scanned = ScannedPort(port: 5432, pid: 812, processName: "postgres")

        model.connect()
        daemon.continuation.yield(.ports([scanned]))
        await settle()
        model.openInBrowser(scanned)

        #expect(model.scannedPorts == [scanned])
        #expect(actions.openedURLs.map(\.absoluteString) == ["http://localhost:5432"])
    }

    @Test("killing an unclaimed port takes the ports the daemon reports back")
    func killingAnUnclaimedPort() async {
        let daemon = FakeDaemonService()
        let model = AppModel(daemon: daemon, applicationActions: FakeApplicationActions())
        let squatter = ScannedPort(port: 3000, pid: 4288, processName: "node")
        daemon.portsToReturn = [ScannedPort(port: 5432, pid: 812, processName: "postgres")]

        model.connect()
        daemon.continuation.yield(.ports([squatter]))
        await settle()
        model.kill(squatter)
        await settle()

        #expect(daemon.commands == [.kill(port: 3000)])
        #expect(model.scannedPorts.map(\.port) == [5432])
        #expect(model.killingPorts.isEmpty)
    }

    @Test("a refused kill surfaces the reason and stops marking the port")
    func refusedKillSurfacesTheReason() async {
        let daemon = FakeDaemonService()
        daemon.failure = DenshaError.portHeldByService(port: 3000, service: "storefront/web")
        let model = AppModel(daemon: daemon, applicationActions: FakeApplicationActions())

        model.kill(ScannedPort(port: 3000, pid: 4288, processName: "node"))
        await settle()

        #expect(
            model.lastError == "port 3000 belongs to storefront/web — stop the service instead")
        #expect(model.killingPorts.isEmpty)
    }

    @Test("services are grouped by project, ungrouped ones first")
    func servicesAreGroupedByProject() async {
        let daemon = FakeDaemonService()
        let model = AppModel(daemon: daemon, applicationActions: FakeApplicationActions())

        model.connect()
        daemon.continuation.yield(
            .services([
                ServiceStatus(name: "postgres", state: .running, pid: 10, pgid: 10, port: 5432),
                ServiceStatus(name: "storefront/web", state: .stopped, port: 3000),
                ServiceStatus(name: "storefront/api", state: .running, pid: 11, pgid: 11),
                ServiceStatus(name: "warehouse/web", state: .stopped, port: 3000),
            ]))
        await settle()

        #expect(model.groups.map(\.project) == [nil, "storefront", "warehouse"])
        #expect(model.groups.map(\.services.count) == [1, 2, 1])
        #expect(model.groups[1].anyLive)
        #expect(!model.groups[1].allLive)
        #expect(!model.groups[2].anyLive)
    }

    @Test("starting a project sends the project, not its services")
    func startingAProjectSendsTheProject() async {
        let daemon = FakeDaemonService()
        let model = AppModel(daemon: daemon, applicationActions: FakeApplicationActions())

        model.connect()
        daemon.continuation.yield(
            .services([
                ServiceStatus(name: "postgres", state: .stopped, port: 5432),
                ServiceStatus(name: "storefront/web", state: .stopped, port: 3000),
                ServiceStatus(name: "storefront/api", state: .stopped),
            ]))
        await settle()

        model.start(model.groups[1])
        model.start(model.groups[0])
        await settle()

        #expect(daemon.commands == [.start(names: ["storefront"]), .start(names: ["postgres"])])
    }

    @Test("service actions use typed daemon commands")
    func serviceActionsUseTypedDaemonCommands() async {
        let daemon = FakeDaemonService()
        let model = AppModel(daemon: daemon, applicationActions: FakeApplicationActions())

        model.start("web")
        await settle()

        #expect(daemon.commands == [.start(names: ["web"])])
    }

    @Test("macOS actions are delegated")
    func macOSActionsAreDelegated() {
        let actions = FakeApplicationActions()
        let model = AppModel(daemon: FakeDaemonService(), applicationActions: actions)

        model.revealInFinder(ServiceStatus(name: "web", state: .running, cwd: "/tmp/web"))
        model.openConfigInEditor()
        model.copyToClipboard("ready in 957 ms")
        model.saveLogFile(for: "web")

        #expect(actions.revealedPaths == ["/tmp/web"])
        #expect(actions.openedConfigCount == 1)
        #expect(actions.copiedText == ["ready in 957 ms"])
        #expect(actions.savedLogServices == ["web"])
    }

    @Test("a failed log save surfaces the error")
    func failedLogSaveSurfacesTheError() {
        let actions = FakeApplicationActions()
        actions.saveLogFileError = DenshaError.noLogFile("web")
        let model = AppModel(daemon: FakeDaemonService(), applicationActions: actions)

        model.saveLogFile(for: "web")

        #expect(model.lastError == "no log file for web")
    }

    @Test("a service in an unknown project creates the project from its folder")
    func newServiceCreatesItsProject() async throws {
        let configFile = temporaryConfigFile()
        let daemon = FakeDaemonService()
        let model = AppModel(
            daemon: daemon, applicationActions: FakeApplicationActions(), configFile: configFile)

        try model.save(
            ServiceDraft(name: "web", command: "pnpm dev", port: 3000),
            project: "storefront", folder: "~/code/storefront")
        await settle()

        let written = try String(contentsOf: configFile, encoding: .utf8)
        #expect(written.contains("[[project]]"))
        #expect(written.contains("name = \"storefront\""))
        #expect(written.contains("cwd = \"~/code/storefront\""))
        #expect(daemon.commands == [.reload])
        #expect(model.serviceEditor == nil)
    }

    @Test("a service joins an existing project and only repeats a folder that differs")
    func newServiceJoinsAnExistingProject() throws {
        let configFile = temporaryConfigFile()
        let model = AppModel(
            daemon: FakeDaemonService(), applicationActions: FakeApplicationActions(),
            configFile: configFile)

        try model.save(
            ServiceDraft(name: "web", command: "pnpm dev"),
            project: "storefront", folder: "~/code/storefront")
        try model.save(
            ServiceDraft(name: "worker", command: "pnpm worker"),
            project: "storefront", folder: "~/code/storefront")
        try model.save(
            ServiceDraft(name: "api", command: "go run ."),
            project: "storefront", folder: "~/code/storefront-api")

        let config = try ConfigLoader.load(from: configFile)
        #expect(
            config.services.map(\.name) == [
                "storefront/web", "storefront/worker", "storefront/api",
            ])
        #expect(
            config.service(named: "storefront/worker")?.cwd
                == ConfigLoader.expandTilde("~/code/storefront"))
        #expect(
            config.service(named: "storefront/api")?.cwd
                == ConfigLoader.expandTilde("~/code/storefront-api"))
    }

    @Test("adding to a project starts from the folder that project already uses")
    func newServiceRequestPrefillsTheProjectFolder() throws {
        let configFile = temporaryConfigFile()
        let model = AppModel(
            daemon: FakeDaemonService(), applicationActions: FakeApplicationActions(),
            configFile: configFile)
        try model.save(
            ServiceDraft(name: "web", command: "pnpm dev"),
            project: "storefront", folder: "~/code/storefront")

        model.requestNewService(project: "storefront")

        #expect(model.serviceEditor?.project == "storefront")
        #expect(model.serviceEditor?.folder == "~/code/storefront")
    }

    @Test("editing a service rewrites its entry in place")
    func editingRewritesTheEntry() throws {
        let configFile = temporaryConfigFile()
        let model = AppModel(
            daemon: FakeDaemonService(), applicationActions: FakeApplicationActions(),
            configFile: configFile)
        try model.save(
            ServiceDraft(name: "web", command: "pnpm dev", port: 3000),
            project: "storefront", folder: "~/code/storefront")
        try model.save(
            ServiceDraft(name: "api", command: "go run ."),
            project: "storefront", folder: "~/code/storefront")

        try model.save(
            ServiceDraft(name: "web", command: "pnpm dev --host", port: 4000, autostart: true),
            project: "storefront", folder: "~/code/storefront", replacing: "storefront/web")

        let config = try ConfigLoader.load(from: configFile)
        #expect(config.services.map(\.name) == ["storefront/web", "storefront/api"])
        let web = try #require(config.service(named: "storefront/web"))
        #expect(web.command == "pnpm dev --host")
        #expect(web.port == 4000)
        #expect(web.autostart)
    }

    @Test("moving a service to another project empties out the one it leaves")
    func movingSheddsAnEmptyProject() throws {
        let configFile = temporaryConfigFile()
        let model = AppModel(
            daemon: FakeDaemonService(), applicationActions: FakeApplicationActions(),
            configFile: configFile)
        try model.save(
            ServiceDraft(name: "web", command: "pnpm dev"),
            project: "storefront", folder: "~/code/storefront")
        try model.save(
            ServiceDraft(name: "api", command: "go run ."),
            project: "warehouse", folder: "~/code/warehouse")

        try model.save(
            ServiceDraft(name: "api", command: "go run ."),
            project: "storefront", folder: "~/code/storefront-api",
            replacing: "warehouse/api")

        let config = try ConfigLoader.load(from: configFile)
        #expect(config.services.map(\.name) == ["storefront/web", "storefront/api"])
        #expect(!(try ConfigDocument.load(from: configFile)).hasProject(named: "warehouse"))
    }

    @Test("a chosen folder is inspected for a project name")
    func chosenFolderIsInspected() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("densha-tests-\(UUID().uuidString)")
            .appendingPathComponent("storefront")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let actions = FakeApplicationActions()
        actions.folderToChoose = directory
        let model = AppModel(daemon: FakeDaemonService(), applicationActions: actions)

        #expect(model.inspectFolder(startingAt: nil)?.projectName == "storefront")
    }

    private func temporaryConfigFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("densha-tests-\(UUID().uuidString)")
            .appendingPathComponent("services.toml")
    }

    private func settle() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}

@MainActor
private final class FakeDaemonService: DaemonServing {
    let continuation: AsyncStream<LinkEvent>.Continuation
    private let stream: AsyncStream<LinkEvent>
    var commands: [DaemonCommand] = []
    var portsToReturn: [ScannedPort]?
    var failure: Error?

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
    }

    func events() -> AsyncStream<LinkEvent> {
        stream
    }

    func run(_ command: DaemonCommand) async throws -> Response {
        commands.append(command)
        if let failure { throw failure }
        return Response(id: commands.count, ok: true, ports: portsToReturn)
    }

    func stop() {
        continuation.finish()
    }
}

@MainActor
private final class FakeApplicationActions: ApplicationActions {
    var revealedPaths: [String] = []
    var openedConfigCount = 0
    var openedURLs: [URL] = []
    var copiedText: [String] = []

    func revealInFinder(path: String) {
        revealedPaths.append(path)
    }

    func openConfig() throws {
        openedConfigCount += 1
    }

    var folderToChoose: URL?

    func chooseFolder(startingAt path: String?) -> URL? {
        folderToChoose
    }

    func open(_ url: URL) {
        openedURLs.append(url)
    }

    func copyToClipboard(_ text: String) {
        copiedText.append(text)
    }

    var savedLogServices: [String] = []
    var saveLogFileError: Error?

    func saveLogFile(for service: String) throws {
        if let saveLogFileError { throw saveLogFileError }
        savedLogServices.append(service)
    }
}
