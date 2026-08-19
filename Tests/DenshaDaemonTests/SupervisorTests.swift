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

    private func service(name: String, port: Int?) -> ResolvedService {
        ResolvedService(
            name: name,
            cwd: "/tmp",
            command: "true",
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
