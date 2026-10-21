import Foundation
import WinkAutomation
import WinkCore
import Testing
@testable import WinkAutomationKit

/// The default service composition must route automation feedback to the
/// visualizer. This wiring was silently missing for a long time — every
/// service fell back to `NoopAutomationFeedbackClient`, so no click, type,
/// scroll, or capture animations were ever emitted.
@MainActor
struct ServiceFeedbackWiringTests {
    @Test
    func `Default services emit visualizer feedback`() {
        let services = WinkServices(snapshotManager: InMemorySnapshotManager())

        let automation = services.automation as? UIAutomationService
        #expect(automation?.feedbackClient is VisualizerAutomationFeedbackClient)

        let windows = services.windows as? WindowManagementService
        #expect(windows?.feedbackClient is VisualizerAutomationFeedbackClient)

        let menu = services.menu as? MenuService
        #expect(menu?.feedbackClient is VisualizerAutomationFeedbackClient)

        let dock = services.dock as? DockService
        #expect(dock?.feedbackClient is VisualizerAutomationFeedbackClient)

        let dialogs = services.dialogs as? DialogService
        #expect(dialogs?.feedbackClient is VisualizerAutomationFeedbackClient)

        let screenCapture = services.screenCapture as? ScreenCaptureService
        #expect(screenCapture?.feedbackClient is VisualizerAutomationFeedbackClient)
    }
}
