import AppKit
import CoreGraphics
import DenshaCore
import Foundation
import IOKit.pwr_mgt
import Observation
import ServiceManagement

enum KeepAwakeMode: Equatable {
    case off
    case whileServicesRun
    case until(Date)
    case untilOff
}

@MainActor
@Observable
final class PowerControls {
    static let shared = PowerControls()

    private static let whileServicesRunKey = "keepAwakeWhileServicesRun"

    private let helper = SMAppService.daemon(plistName: powerHelperPlistName)
    private var sleepAssertion: IOPMAssertionID = 0
    private var assertionHeld = false
    private var expiryTask: Task<Void, Never>?
    private var cursorMovementTask: Task<Void, Never>?
    private var cursorMovementActivity: NSObjectProtocol?

    private init() {
        if UserDefaults.standard.bool(forKey: Self.whileServicesRunKey) {
            keepAwakeMode = .whileServicesRun
        }
    }

    private(set) var keepAwakeMode: KeepAwakeMode = .off
    private(set) var cursorMovementIntervalMinutes: Int?
    private(set) var needsPostEventAccess = false

    var servicesAreLive = false {
        didSet { applyKeepAwake() }
    }

    var keepAwakeActive: Bool {
        Self.holdsAssertion(mode: keepAwakeMode, servicesLive: servicesAreLive)
    }

    var overrideActive: Bool { keepAwakeActive || lidSleepDisabled }

    func setKeepAwake(_ mode: KeepAwakeMode) {
        expiryTask?.cancel()
        expiryTask = nil
        keepAwakeMode = mode
        UserDefaults.standard.set(
            mode == .whileServicesRun, forKey: Self.whileServicesRunKey)
        if case .until(let date) = mode {
            expiryTask = Task {
                try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                keepAwakeMode = .off
                applyKeepAwake()
            }
        }
        applyKeepAwake()
    }

    nonisolated static func holdsAssertion(mode: KeepAwakeMode, servicesLive: Bool) -> Bool {
        switch mode {
        case .off: false
        case .whileServicesRun: servicesLive
        case .until(let date): date > Date()
        case .untilOff: true
        }
    }

    var cursorMovementActive: Bool {
        cursorMovementIntervalMinutes != nil
    }

    func setCursorMovement(intervalMinutes: Int?) {
        cursorMovementTask?.cancel()
        cursorMovementTask = nil
        cursorMovementIntervalMinutes = nil
        if let cursorMovementActivity {
            ProcessInfo.processInfo.endActivity(cursorMovementActivity)
        }
        cursorMovementActivity = nil
        guard let intervalMinutes, intervalMinutes > 0 else {
            needsPostEventAccess = false
            return
        }
        // CGRequestPostEventAccess only opens the prompt: it answers false until the
        // approval lands, so take the selection anyway and say what is still missing.
        needsPostEventAccess = !(CGPreflightPostEventAccess() || CGRequestPostEventAccess())
        cursorMovementIntervalMinutes = intervalMinutes
        // Densha is LSUIElement, so App Nap throttles its timers once the panel closes and
        // stretches this sleep well past the idle threshold the nudge exists to beat. The
        // activity stops the throttling without holding the Mac awake — that is the other
        // switch's job.
        cursorMovementActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "moving the cursor")
        cursorMovementTask = Task {
            while !Task.isCancelled {
                // A stale accessibility grant preflights as approved and then drops every
                // posted event, so trust the idle clock rather than the permission answer.
                needsPostEventAccess = !Self.nudgeCursor()
                do {
                    try await Task.sleep(for: .seconds(intervalMinutes * 60))
                } catch {
                    return
                }
            }
        }
    }

    nonisolated static func cursorNudgePoint(from point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + (point.x > 0 ? -1 : 1), y: point.y)
    }

    /// Nudges the cursor and answers whether the move actually reached the system, which is
    /// the only reliable sign that posting events is permitted.
    @discardableResult
    private nonisolated static func nudgeCursor() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let current = CGEvent(source: source)?.location ?? .zero
        let moved = cursorNudgePoint(from: current)
        CGEvent(
            mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: moved, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(
            mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: current, mouseButton: .left)?.post(tap: .cghidEventTap)
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .mouseMoved) < 1
    }

    private func applyKeepAwake() {
        let wanted = keepAwakeActive
        guard wanted != assertionHeld else { return }
        if wanted {
            // Display, not system: PreventUserIdleSystemSleep keeps the CPU up
            // but lets the screen go black and lock, which is what users read as asleep.
            // This one covers idle system sleep too, so it is the only assertion needed.
            let created = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Densha keeps the Mac awake" as CFString,
                &sleepAssertion)
            assertionHeld = created == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
            assertionHeld = false
        }
    }

    private(set) var lidSleepDisabled = false
    private(set) var helperStatus: SMAppService.Status = .notRegistered

    func refresh() {
        helperStatus = helper.status
        if cursorMovementActive {
            needsPostEventAccess = !CGPreflightPostEventAccess()
        }
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

    func openAccessibilitySettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
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
