import Darwin
import Testing
@testable import WinkCLI

struct ClickCommandCoordsCrashRegressionTests {
    @Test
    @MainActor
    func `click --at ',' returns failure (no crash)`() async {
        let status = await executeWinkCLI(arguments: ["wink", "click", "--at", ",", "--json"])
        #expect(status == EXIT_FAILURE)
    }
}
