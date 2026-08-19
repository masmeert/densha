import Testing

@testable import DenshaCore
@testable import DenshaDaemon

@Suite("Port scanner")
struct PortScannerTests {
    @Test("a running service owns its port through its process group, declared or not")
    func runningServicePortsAreExcluded() {
        let kept = PortScanner.unclaimed(
            among: [listening(port: 3000, pid: 900), listening(port: 8081, pid: 901)],
            services: [
                running(name: "admin", pgid: 900, port: 3000),
                running(name: "native", pgid: 901, port: nil),
            ],
            processGroupOf: { $0 })

        #expect(kept.isEmpty)
    }

    @Test("a stopped service's port held by a foreign process is a conflict, not a hidden row")
    func foreignProcessOnDeclaredPortIsAConflict() {
        let kept = PortScanner.unclaimed(
            among: [listening(port: 3000, pid: 700)],
            services: [ServiceStatus(name: "admin", state: .stopped, port: 3000)],
            processGroupOf: { $0 })

        #expect(kept.map(\.port) == [3000])
        #expect(kept.first?.conflictsWith == "admin")
    }

    @Test("a live service keeps its declared port even when something else answers on it")
    func livePortsStayWithTheirService() {
        let kept = PortScanner.unclaimed(
            among: [listening(port: 3000, pid: 700)],
            services: [running(name: "admin", pgid: 900, port: 3000)],
            processGroupOf: { $0 })

        #expect(kept.isEmpty)
    }

    @Test("conflicts sort above the merely unclaimed")
    func conflictsComeFirst() {
        let kept = PortScanner.unclaimed(
            among: [
                listening(port: 5432, pid: 30),
                listening(port: 8081, pid: 31),
                listening(port: 1234, pid: 32),
            ],
            services: [ServiceStatus(name: "native", state: .stopped, port: 8081)],
            processGroupOf: { $0 })

        #expect(kept.map(\.port) == [8081, 1234, 5432])
        #expect(kept.map(\.conflictsWith) == ["native", nil, nil])
    }

    @Test("the first service declaring a port owns the conflict")
    func firstDeclaringServiceOwnsTheConflict() {
        let kept = PortScanner.unclaimed(
            among: [listening(port: 3000, pid: 700)],
            services: [
                ServiceStatus(name: "admin", state: .stopped, port: 3000),
                ServiceStatus(name: "admin-legacy", state: .stopped, port: 3000),
            ],
            processGroupOf: { $0 })

        #expect(kept.first?.conflictsWith == "admin")
    }

    @Test("privileged and ephemeral ports are out of scanning range")
    func onlyDeveloperPortsSurvive() {
        let kept = PortScanner.unclaimed(
            among: [
                listening(port: 22, pid: 1),
                listening(port: 631, pid: 2),
                listening(port: 1024, pid: 3),
                listening(port: 49151, pid: 4),
                listening(port: 49152, pid: 5),
                listening(port: 63321, pid: 6),
            ],
            services: [],
            processGroupOf: { $0 })

        #expect(kept.map(\.port) == [1024, 49151])
    }

    @Test("macOS background services are not worth showing")
    func systemProcessesAreIgnored() {
        let kept = PortScanner.unclaimed(
            among: [
                ScannedPort(port: 5000, pid: 20, processName: "ControlCenter"),
                ScannedPort(port: 7000, pid: 20, processName: "ControlCenter"),
                ScannedPort(port: 8080, pid: 21, processName: "node"),
            ],
            services: [],
            processGroupOf: { $0 })

        #expect(kept.map(\.processName) == ["node"])
    }

    @Test("scan rules from services.toml hide noisy ports and processes")
    func configuredIgnoresAreHonoured() {
        let kept = PortScanner.unclaimed(
            among: [
                ScannedPort(port: 15292, pid: 40, processName: "Adobe Desktop Service"),
                ScannedPort(port: 5432, pid: 41, processName: "OrbStack Helper"),
                ScannedPort(port: 8080, pid: 42, processName: "node"),
            ],
            services: [],
            rules: PortScanRules(
                ignoredPorts: [15292], ignoredProcessNames: ["OrbStack Helper"]),
            processGroupOf: { $0 })

        #expect(kept.map(\.port) == [8080])
    }

    @Test("one row per port, ordered by port")
    func resultsAreDedupedAndSorted() {
        let kept = PortScanner.unclaimed(
            among: [
                listening(port: 8080, pid: 30),
                listening(port: 3000, pid: 31),
                listening(port: 8080, pid: 30),
            ],
            services: [],
            processGroupOf: { $0 })

        #expect(kept.map(\.port) == [3000, 8080])
    }

    @Test("scanning the machine reports plausible listeners")
    func scanningTheMachineWorks() {
        for scanned in PortScanner.listeningPorts() {
            #expect((1...65535).contains(scanned.port))
            #expect(scanned.pid > 0)
            #expect(!scanned.processName.isEmpty)
        }
    }

    private func listening(port: Int, pid: Int32) -> ScannedPort {
        ScannedPort(port: port, pid: pid, processName: "node")
    }

    private func running(name: String, pgid: Int32, port: Int?) -> ServiceStatus {
        ServiceStatus(name: name, state: .running, pid: pgid, pgid: pgid, port: port)
    }
}
