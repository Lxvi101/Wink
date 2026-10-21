import Foundation
import Testing
@testable import WinkCLI

#if !WINK_SKIP_AUTOMATION
@Suite(
    .serialized,
    .tags(.automation),
    .enabled(if: CLITestEnvironment.runAutomationRead)
)
struct ClickCommandFocusTests {
    private func runWinkCommand(
        _ arguments: [String],
        allowedExitStatuses: Set<Int32> = [0]
    ) async throws -> CommandRunResult {
        try await InProcessCommandRunner.runShared(arguments, allowedExitCodes: allowedExitStatuses)
    }

    @Test
    func `click help shows focus options`() async throws {
        let result = try await self.runWinkCommand(["click", "--help"])
        let output = result.combinedOutput

        #expect(output.contains("--foreground"))
        #expect(output.contains("--no-auto-focus"))
        #expect(output.contains("--focus-timeout"))
        #expect(output.contains("--focus-retry-count"))
        #expect(output.contains("--space-switch"))
        #expect(output.contains("--bring-to-current-space"))
    }

    // Snapshot-based click behavior is validated in opt-in end-to-end suites.
}
#endif
