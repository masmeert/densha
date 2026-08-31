import DenshaCore
import Foundation
import IOKit.pwr_mgt
import Observation
import ServiceManagement

@MainActor
@Observable
final class PowerControls {
    static let shared = PowerControls()

    private let helper = SMAppService.daemon(plistName: powerHelperPlistName)
    private var sleepAssertion: IOPMAssertionID = 0

    var keepAwake = false {
        didSet {
            guard keepAwake != oldValue else { return }
            if keepAwake {
                IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "Densha keeps the Mac awake" as CFString,
                    &sleepAssertion)
            } else {
                IOPMAssertionRelease(sleepAssertion)
            }
        }
    }

    private(set) var lidSleepDisabled = false
    private(set) var helperStatus: SMAppService.Status = .notRegistered

    func refresh() {
        helperStatus = helper.status
        Task {
            let output = await Self.run("/usr/bin/pmset", "-g") ?? ""
            lidSleepDisabled = Self.sleepDisabled(inPmsetOutput: output)
        }
    }

    func setLidSleepDisabled(_ disabled: Bool) {
        Task {
            if helper.status != .enabled {
                try? helper.register()
            }
            if helper.status == .enabled {
                if await !Self.helperSetSleepDisabled(disabled) {
                    await Self.adminSetSleepDisabled(disabled)
                }
            } else {
                await Self.adminSetSleepDisabled(disabled)
            }
            refresh()
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    nonisolated static func sleepDisabled(inPmsetOutput output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            line.contains("SleepDisabled")
                && line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
    }

    private nonisolated static func adminSetSleepDisabled(_ disabled: Bool) async {
        _ = await run(
            "/usr/bin/osascript", "-e",
            """
            do shell script "pmset -a disablesleep \(disabled ? 1 : 0)" \
            with administrator privileges
            """)
    }

    private nonisolated static func helperSetSleepDisabled(_ disabled: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let call = PowerHelperCall(continuation: continuation)
            guard
                let proxy = call.connection.remoteObjectProxyWithErrorHandler({ _ in
                    call.finish(false)
                }) as? PowerHelperCommands
            else {
                call.finish(false)
                return
            }
            proxy.setSleepDisabled(disabled) { ok in call.finish(ok) }
        }
    }

    private nonisolated static func run(_ executable: String, _ arguments: String...) async
        -> String?
    {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}

private final class PowerHelperCall: @unchecked Sendable {
    let connection: NSXPCConnection
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
        connection = NSXPCConnection(machServiceName: powerHelperMachService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperCommands.self)
        connection.resume()
    }

    func finish(_ ok: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection.invalidate()
        pending.resume(returning: ok)
    }
}
