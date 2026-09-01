import Foundation
import Testing

@testable import DenshaUI

@Suite struct PowerControlsTests {
    @Test func keepAwakeAssertionFollowsMode() {
        #expect(!PowerControls.holdsAssertion(mode: .off, servicesLive: true))
        #expect(PowerControls.holdsAssertion(mode: .untilOff, servicesLive: false))
        #expect(PowerControls.holdsAssertion(mode: .whileServicesRun, servicesLive: true))
        #expect(!PowerControls.holdsAssertion(mode: .whileServicesRun, servicesLive: false))
        #expect(PowerControls.holdsAssertion(mode: .until(.now + 60), servicesLive: false))
        #expect(!PowerControls.holdsAssertion(mode: .until(.now - 60), servicesLive: false))
    }

    @Test func detectsSleepDisabled() {
        let enabled = """
            System-wide power settings:
             SleepDisabled\t\t1
            Currently in use:
             standby              1
            """
        #expect(PowerControls.sleepDisabled(inPmsetOutput: enabled))
    }

    @Test func detectsSleepEnabled() {
        let disabled = """
            System-wide power settings:
             SleepDisabled\t\t0
            Currently in use:
             standby              1
            """
        #expect(!PowerControls.sleepDisabled(inPmsetOutput: disabled))
        #expect(!PowerControls.sleepDisabled(inPmsetOutput: ""))
    }

    // The regression this guards: a PreventUserIdleSystemSleep assertion keeps the CPU
    // up but lets the screen black out and lock, which users read as the Mac sleeping.
    @MainActor
    @Test func keepAwakeHoldsADisplaySleepAssertion() async throws {
        let power = PowerControls.shared
        power.setKeepAwake(.untilOff)
        defer { power.setKeepAwake(.off) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)

        // Scope to this process: a Densha app running on the same Mac holds an
        // identically named assertion and would answer for it.
        let pid = "pid \(ProcessInfo.processInfo.processIdentifier)("
        let ours = output.split(separator: "\n").filter {
            $0.contains("Densha keeps the Mac awake") && $0.contains(pid)
        }
        #expect(!ours.isEmpty)
        #expect(ours.allSatisfy { $0.contains("PreventUserIdleDisplaySleep") })
    }

    // The selection has to stick even where posting events is not permitted, which
    // is exactly what a test host is: an unapproved process.
    @MainActor
    @Test func cursorMovementSelectionSticksWithoutEventAccess() {
        let power = PowerControls.shared
        power.setCursorMovement(intervalMinutes: 3)
        #expect(power.cursorMovementIntervalMinutes == 3)
        #expect(power.cursorMovementActive)

        power.setCursorMovement(intervalMinutes: nil)
        #expect(power.cursorMovementIntervalMinutes == nil)
        #expect(!power.needsPostEventAccess)
    }

    @Test func cursorNudgeMovesOnePointHorizontally() {
        #expect(
            PowerControls.cursorNudgePoint(from: CGPoint(x: 100, y: 20))
                == CGPoint(x: 99, y: 20))
        #expect(
            PowerControls.cursorNudgePoint(from: CGPoint(x: 0, y: 20))
                == CGPoint(x: 1, y: 20))
    }
}
