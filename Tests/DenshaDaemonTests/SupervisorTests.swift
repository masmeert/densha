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

        let targets = await supervisor.resolveTargets(["apmoove"])

        #expect(targets.names == ["apmoove/web", "apmoove/api"])
        #expect(targets.errors.isEmpty)
    }

    @Test("a qualified name targets exactly one service")
    func qualifiedNameTargetsOneService() async {
        let supervisor = Supervisor(config: Config(services: twoProjects))

        let targets = await supervisor.resolveTargets(["caisse/web"])

        #expect(targets.names == ["caisse/web"])
    }

    @Test("a bare name resolves when only one project defines it")
    func bareNameResolvesWhenUnique() async {
        let supervisor = Supervisor(config: Config(services: twoProjects))

        let targets = await supervisor.resolveTargets(["api"])

        #expect(targets.names == ["apmoove/api"])
        #expect(targets.errors.isEmpty)
    }

    @Test("a bare name shared by two projects is reported as ambiguous")
    func bareNameCanBeAmbiguous() async {
        let supervisor = Supervisor(config: Config(services: twoProjects))

        let targets = await supervisor.resolveTargets(["web"])

        #expect(targets.names.isEmpty)
        #expect(targets.errors["web"] == "ambiguous — did you mean apmoove/web, caisse/web?")
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
                "apmoove/web", "apmoove/api", "caisse/web",
            ])
        #expect(
            await supervisor.resolveTargets(["apmoove", "apmoove/web"]).names
                == ["apmoove/web", "apmoove/api"])
    }

    @Test("starting a project stops whatever holds the ports it needs")
    func startingAProjectFreesItsPorts() async {
        let supervisor = Supervisor(config: Config(services: twoProjects))

        _ = await supervisor.start(names: ["caisse"])
        let squatter = await supervisor.snapshot().first { $0.name == "caisse/web" }
        #expect(squatter?.isLive == true)

        _ = await supervisor.start(names: ["apmoove"])
        let after = await supervisor.snapshot()

        #expect(after.first { $0.name == "caisse/web" }?.isLive == false)
        #expect(after.first { $0.name == "apmoove/web" }?.isLive == true)
        #expect(after.first { $0.name == "apmoove/api" }?.isLive == true)

        await supervisor.stopAll()
    }

    @Test("one batch cannot start two services that want the same port")
    func aBatchStartsOnePortOnce() async {
        let supervisor = Supervisor(config: Config(services: twoProjects))

        let errors = await supervisor.start(names: nil)

        #expect(
            errors["caisse/web"]
                == "port 3000 is also declared by apmoove/web — start one at a time")
        #expect(await supervisor.snapshot().first { $0.name == "apmoove/web" }?.isLive == true)

        await supervisor.stopAll()
    }

    private var twoProjects: [ResolvedService] {
        [
            service(name: "apmoove/web", port: 3000),
            service(name: "apmoove/api", port: 8080),
            service(name: "caisse/web", port: 3000),
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
