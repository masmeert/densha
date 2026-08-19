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

    @Test("services are grouped by project, ungrouped ones first")
    func servicesAreGroupedByProject() async {
        let daemon = FakeDaemonService()
        let model = AppModel(daemon: daemon, applicationActions: FakeApplicationActions())

        model.connect()
        daemon.continuation.yield(
            .services([
                ServiceStatus(name: "postgres", state: .running, pid: 10, pgid: 10, port: 5432),
                ServiceStatus(name: "apmoove/web", state: .stopped, port: 3000),
                ServiceStatus(name: "apmoove/api", state: .running, pid: 11, pgid: 11),
                ServiceStatus(name: "caisse/web", state: .stopped, port: 3000),
            ]))
        await settle()

        #expect(model.groups.map(\.project) == [nil, "apmoove", "caisse"])
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
                ServiceStatus(name: "apmoove/web", state: .stopped, port: 3000),
                ServiceStatus(name: "apmoove/api", state: .stopped),
            ]))
        await settle()

        model.start(model.groups[1])
        model.start(model.groups[0])
        await settle()

        #expect(daemon.commands == [.start(names: ["apmoove"]), .start(names: ["postgres"])])
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

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
    }

    func events() -> AsyncStream<LinkEvent> {
        stream
    }

    func run(_ command: DaemonCommand) async throws -> Response {
        commands.append(command)
        return Response(id: commands.count, ok: true)
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
