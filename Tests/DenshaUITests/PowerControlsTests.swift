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
}
