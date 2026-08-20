import Foundation
import Testing

@testable import DenshaCore
@testable import DenshaDaemon

@Suite("Supervisor")
struct SupervisorTests {
    @Test("initial snapshot follows configuration order")
    func initialSnapshotFollowsConfigurationOrder() async {
        let services = [
            service(name: "web", port: 3000),
            service(name: "api", port: 8080),
        ]
        let supervisor = Supervisor(config: Config(services: services))

        let snapshot = await supervisor.snapshot()

        #expect(snapshot.map(\.name) == ["web", "api"])
        #expect(snapshot.map(\.state) == [.stopped, .stopped])
        #expect(snapshot.map(\.port) == [3000, 8080])
    }

    @Test("a project name targets every service in it")
    func projectNameTargetsItsServices() async {
        let supervisor = Supervisor(config: Config(services: twoProjects))

        let targets = await supervisor.resolveTargets(["storefront"])

        #expect(targets.names == ["storefront/web", "storefront/api"])
        #expect(targets.errors.isEmpty)
    }

    @Test("a qualified name targets exactly one service")
    func qualifiedNameTargetsOneService() async {
        let supervisor = Supervisor(config: Config(services: twoProjects))

        let targets = await supervisor.resolveTargets(["warehouse/web"])

        #expect(targets.names == ["warehouse/web"])
    }

    @Test("a bare name resolves when only one project defines it")
    func bareNameResolvesWhenUnique() async {
        let supervisor = Supervisor(config: Config(services: twoProjects))

        let targets = await supervisor.resolveTargets(["api"])

        #expect(targets.names == ["storefront/api"])
        #expect(targets.errors.isEmpty)
    }

    @Test("a bare name shared by two projects is reported as ambiguous")
    func bareNameCanBeAmbiguous() async {
        let supervisor = Supervisor(config: Config(services: twoProjects))

        let targets = await supervisor.resolveTargets(["web"])

        #expect(targets.names.isEmpty)
        #expect(targets.errors["web"] == "ambiguous — did you mean storefront/web, warehouse/web?")
    }

    @Test("an unknown target is named in the errors")
    func unknownTargetIsReported() async {
        let supervisor = Supervisor(config: Config(services: twoProjects))

        let targets = await supervisor.resolveTargets(["nope"])

        #expect(targets.errors["nope"] == "no such service")
    }

    @Test("targeting everything keeps configuration order and drops duplicates")
    func everythingKeepsOrder() async {
        let supervisor = Supervisor(config: Config(services: twoProjects))

        #expect(
            await supervisor.resolveTargets(nil).names == [
                "storefront/web", "storefront/api", "warehouse/web",
            ])
        #expect(
            await supervisor.resolveTargets(["storefront", "storefront/web"]).names
                == ["storefront/web", "storefront/api"])
    }

    @Test("starting a project stops whatever holds the ports it needs")
    func startingAProjectFreesItsPorts() async {
        let supervisor = Supervisor(config: Config(services: twoProjects))

        _ = await supervisor.start(names: ["warehouse"])
        let squatter = await supervisor.snapshot().first { $0.name == "warehouse/web" }
        #expect(squatter?.isLive == true)

        _ = await supervisor.start(names: ["storefront"])
        let after = await supervisor.snapshot()

        #expect(after.first { $0.name == "warehouse/web" }?.isLive == false)
        #expect(after.first { $0.name == "storefront/web" }?.isLive == true)
        #expect(after.first { $0.name == "storefront/api" }?.isLive == true)

        await supervisor.stopAll()
    }

    @Test("one batch cannot start two services that want the same port")
    func aBatchStartsOnePortOnce() async {
        let supervisor = Supervisor(config: Config(services: twoProjects))

        let errors = await supervisor.start(names: nil)

        #expect(
            errors["warehouse/web"]
                == "port 3000 is also declared by storefront/web — start one at a time")
        #expect(await supervisor.snapshot().first { $0.name == "storefront/web" }?.isLive == true)

        await supervisor.stopAll()
    }

    @Test("killing an unclaimed port ends the process that holds it")
    func killingAnUnclaimedPortEndsItsProcess() async throws {
        let port = 47_291
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        listener.arguments = ["-l", "127.0.0.1", "\(port)"]
        try listener.run()
        defer { if listener.isRunning { listener.terminate() } }

        let supervisor = Supervisor(config: Config(services: []))
        var listed = false
        for _ in 0..<40 where !listed {
            listed = await supervisor.rescanPorts().contains { $0.port == port }
            if !listed { try? await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(listed)

        let remaining = try await supervisor.killProcess(onPort: port)

        #expect(!remaining.contains { $0.port == port })
        listener.waitUntilExit()
        #expect(listener.terminationReason == .uncaughtSignal)
    }

    @Test("a port that nothing unclaimed listens on cannot be killed")
    func killingAQuietPortIsRefused() async {
        let supervisor = Supervisor(config: Config(services: []))

        await #expect(throws: DenshaError.self) {
            _ = try await supervisor.killProcess(onPort: 1)
        }
    }

    private var twoProjects: [ResolvedService] {
        [
            service(name: "storefront/web", port: 3000),
            service(name: "storefront/api", port: 8080),
            service(name: "warehouse/web", port: 3000),
        ]
    }

    private func service(name: String, port: Int?) -> ResolvedService {
        ResolvedService(
            name: name,
            cwd: "/tmp",
            command: "sleep 30",
            port: port,
            autostart: false,
            env: [:],
            shell: "/bin/sh",
            shellArgs: ["-c"],
            stopTimeout: 1,
            restartGrace: 0,
            health: nil
        )
    }
}
