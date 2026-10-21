import WinkAutomationKit
import WinkFoundation
import Testing
@testable import WinkBridge

struct WinkBridgeDockLaunchReceiptSemanticsTests {
    @Test
    func `receipt semantic gate rejects background Dock launch ambiguity`() {
        let request = WinkBridgeRequest.projectedAction(.init(
            request: .launchDockItem(.init(appName: "Safari"))))
        let foreground = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one)
        let background = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)

        #expect(WinkBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            foreground,
            request: request))
        #expect(!WinkBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            background,
            request: request))
    }
}
