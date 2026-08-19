import DenshaCore
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
    var copiedText: [String] = []

    func revealInFinder(path: String) {
        revealedPaths.append(path)
    }

    func openConfig() throws {
        openedConfigCount += 1
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
