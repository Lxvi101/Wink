import Foundation
import WinkFoundation
import WinkFoundationTestSupport
import Testing
@testable import WinkAutomationKit
@testable import WinkBridge

@Suite("Bridge targeted-click value semantics")
struct WinkBridgeTargetedClickValueSemanticsTests {
    @Test
    func `coordinate single click retains conditional unverified value delivery`() {
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 9001,
            ownerProcessStartIdentity: 7,
            capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)

        for policy: Bool? in [nil, true, false] {
            for kind in [ClickType.single, .right, .double, .middle, .triple, .longPress] {
                let request = WinkBridgeRequest.targetedClick(.init(
                    target: .coordinates(CGPoint(x: 30, y: 40)),
                    clickType: kind,
                    snapshotId: SnapshotReferenceFixtures.first.rawValue,
                    targetProcessIdentifier: identity.ownerProcessIdentifier,
                    targetWindowID: identity.windowID,
                    expectedWindowIdentity: identity,
                    expectedWindowBounds: identity.capturedBounds,
                    allowsAccessibilityValueDelivery: policy))
                #expect(WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                    outcome,
                    response: .ok,
                    request: request) == (kind == .single && policy != false))
            }
        }
    }

    @Test
    func `single targeted click accepts one verified background focus value write`() throws {
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 9001,
            ownerProcessStartIdentity: 7,
            capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let bounds = try #require(identity.capturedBounds)
        let focus = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            unitCount: .one)

        for request in [
            WinkBridgeRequest.targetedClick(.init(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue,
                targetProcessIdentifier: identity.ownerProcessIdentifier,
                expectedProcessIdentity: identity.processIdentity,
                allowsAccessibilityValueDelivery: true)),
            WinkBridgeRequest.targetedClick(.init(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue,
                targetProcessIdentifier: identity.ownerProcessIdentifier,
                targetWindowID: identity.windowID,
                expectedWindowIdentity: identity,
                expectedWindowBounds: bounds,
                allowsAccessibilityValueDelivery: true)),
            WinkBridgeRequest.targetedClick(.init(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue,
                targetProcessIdentifier: identity.ownerProcessIdentifier,
                expectedProcessIdentity: identity.processIdentity)),
            WinkBridgeRequest.targetedClick(.init(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue,
                targetProcessIdentifier: identity.ownerProcessIdentifier,
                targetWindowID: identity.windowID,
                expectedWindowIdentity: identity,
                expectedWindowBounds: bounds)),
        ] {
            #expect(WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                focus,
                response: .ok,
                request: request))
        }

        let optedOut = WinkBridgeRequest.targetedClick(.init(
            target: .elementId("field"),
            clickType: .single,
            snapshotId: SnapshotReferenceFixtures.first.rawValue,
            targetProcessIdentifier: identity.ownerProcessIdentifier,
            expectedProcessIdentity: identity.processIdentity,
            allowsAccessibilityValueDelivery: false))
        #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            focus,
            response: .ok,
            request: optedOut))

        let exactOptedOut = WinkBridgeRequest.targetedClick(.init(
            target: .elementId("field"),
            clickType: .single,
            snapshotId: SnapshotReferenceFixtures.first.rawValue,
            targetProcessIdentifier: identity.ownerProcessIdentifier,
            targetWindowID: identity.windowID,
            expectedWindowIdentity: identity,
            expectedWindowBounds: bounds,
            allowsAccessibilityValueDelivery: false))
        #expect(!WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            focus,
            response: .ok,
            request: exactOptedOut))
    }
}
