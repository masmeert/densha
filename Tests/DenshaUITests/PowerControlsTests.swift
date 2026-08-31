import Testing

@testable import DenshaUI

@Suite struct PowerControlsTests {
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
