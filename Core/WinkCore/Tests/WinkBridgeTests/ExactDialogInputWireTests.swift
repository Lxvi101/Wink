import CoreGraphics
import Foundation
import WinkAutomationKit
import WinkFoundation
import Testing
@testable import WinkBridge

struct ExactDialogInputWireTests {
    @Test
    func `protocol 1 27 gates exact dialog execution while retaining legacy input`() {
        let operations: Set<WinkBridgeOperation> = [
            .dialogEnterText,
            .exactDialogEnterText,
            .exactDialogForceDismiss,
        ]
        let legacyVersion = WinkBridgeProtocolVersion(major: 1, minor: 26)

        #expect(WinkBridgeConstants.protocolVersion >=
            WinkBridgeConstants.exactForcedDialogDismissExecutionVersion)
        #expect(WinkBridgeConstants.attestedOperationReceiptVersion == .init(major: 1, minor: 29))
        #expect(WinkBridgeConstants.plannerInventoryTransportVersion == .init(major: 1, minor: 30))
        #expect(WinkBridgeConstants.exactDialogInputExecutionVersion == .init(major: 1, minor: 27))
        #expect(WinkBridgeConstants.exactForcedDialogDismissExecutionVersion == .init(major: 1, minor: 28))
        #expect(WinkBridgeHostCapability.exactDialogInputExecution == "exactDialogInputExecution")
        #expect(WinkBridgeHostCapability.exactForcedDialogDismissExecution ==
            "exactForcedDialogDismissExecution")
        #expect(WinkBridgeOperation.exactDialogEnterText.requiredPermissions == [.accessibility])
        #expect(WinkBridgeOperation.exactDialogForceDismiss.requiredPermissions == [.accessibility, .postEvent])
        #expect(WinkBridgeOperation.compatible(operations, with: legacyVersion) == [.dialogEnterText])
        #expect(WinkBridgeOperation.compatible(
            operations,
            with: .init(major: 1, minor: 27)) == [.dialogEnterText, .exactDialogEnterText])
        #expect(WinkBridgeOperation.compatible(
            operations,
            with: WinkBridgeConstants.protocolVersion) == operations)
    }

    @Test
    func `exact forced dismiss request round trip retains selector and focus policy`() throws {
        let request = try DialogForcedDismissExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242, windowID: 700),
            focus: DialogForegroundFocusPolicy(
                autoFocus: false,
                timeout: 1.5,
                retryCount: 6,
                switchSpace: true,
                bringToCurrentSpace: false))

        let data = try JSONEncoder.winkBridgeEncoder().encode(
            WinkBridgeRequest.exactDialogForceDismiss(request))
        let decoded = try JSONDecoder.winkBridgeDecoder().decode(WinkBridgeRequest.self, from: data)

        #expect(decoded.operation == .exactDialogForceDismiss)
        guard case let .exactDialogForceDismiss(decodedRequest) = decoded else {
            Issue.record("Expected exact forced dialog dismissal request")
            return
        }
        #expect(decodedRequest == request)
        #expect(decoded.desktopOperationScope == .global)
    }

    @Test
    func `legacy dialog input payload keeps old decoding and carries optional focus policy`() throws {
        let oldData = Data(#"{"text":"legacy","clearExisting":false}"#.utf8)
        let oldPayload = try JSONDecoder.winkBridgeDecoder().decode(
            WinkBridgeDialogEnterTextRequest.self,
            from: oldData)
        #expect(oldPayload.focus == nil)

        let policy = DialogForegroundFocusPolicy(autoFocus: false, timeout: 1.25, retryCount: 5)
        let payload = WinkBridgeDialogEnterTextRequest(
            text: "current",
            fieldIdentifier: nil,
            clearExisting: false,
            windowTitle: nil,
            appName: nil,
            focus: policy)
        let data = try JSONEncoder.winkBridgeEncoder().encode(payload)
        let decoded = try JSONDecoder.winkBridgeDecoder().decode(
            WinkBridgeDialogEnterTextRequest.self,
            from: data)
        #expect(decoded.focus == policy)
    }

    @Test
    func `protocol 1 27 synthesized client decodes a 1 28 host handshake without the new operation`() throws {
        let negotiated = WinkBridgeProtocolVersion(major: 1, minor: 27)
        let compatible = WinkBridgeOperation.compatible(
            [.dialogEnterText, .exactDialogEnterText, .exactDialogForceDismiss],
            with: negotiated).sorted { $0.rawValue < $1.rawValue }
        let response = WinkBridgeHandshakeResponse(
            negotiatedVersion: negotiated,
            hostKind: .gui,
            build: nil,
            supportedOperations: compatible,
            enabledOperations: compatible,
            hostCapabilities: [
                WinkBridgeHostCapability.exactDialogInputExecution,
                WinkBridgeHostCapability.exactForcedDialogDismissExecution,
            ])

        let data = try JSONEncoder.winkBridgeEncoder().encode(response)
        let legacy = try JSONDecoder.winkBridgeDecoder().decode(
            LegacyProtocol127Handshake.self,
            from: data)

        #expect(legacy.supportedOperations == [.dialogEnterText, .exactDialogEnterText])
        #expect(legacy.enabledOperations == [.dialogEnterText, .exactDialogEnterText])
        #expect(legacy.hostCapabilities.contains("exactDialogInputExecution"))
    }

    @Test
    func `exact input request round trip retains target text field clear and focus policy`() throws {
        let target = try DialogTargetSelector(
            processIdentifier: 4242,
            windowID: 700)
        let request = try DialogInputExecutionRequest(
            target: target,
            text: "bridge payload",
            fieldIdentifier: "Account name",
            clearExisting: true,
            focus: DialogForegroundFocusPolicy(
                autoFocus: false,
                timeout: 2.75,
                retryCount: 4,
                switchSpace: true,
                bringToCurrentSpace: true))
        let wireRequest = WinkBridgeRequest.exactDialogEnterText(request)

        let data = try JSONEncoder.winkBridgeEncoder().encode(wireRequest)
        let decoded = try JSONDecoder.winkBridgeDecoder().decode(WinkBridgeRequest.self, from: data)

        #expect(decoded.operation == .exactDialogEnterText)
        guard case let .exactDialogEnterText(decodedRequest) = decoded else {
            Issue.record("Expected exact dialog input request")
            return
        }
        #expect(decodedRequest == request)
    }

    @Test
    func `dialog result round trip retains typed target receipt and canonical outcome`() throws {
        let bounds = CGRect(x: 10, y: 20, width: 480, height: 320)
        let identity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 4242,
            ownerProcessStartIdentity: 99,
            capturedBounds: bounds)
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: identity.ownerProcessIdentifier,
            processStartIdentity: identity.ownerProcessStartIdentity,
            windowID: identity.windowID)
        let result = DialogActionResult(
            success: true,
            action: .enterText,
            details: ["focus_policy": "require_existing"],
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted),
            targetReceipt: receipt)

        let data = try JSONEncoder.winkBridgeEncoder().encode(WinkBridgeResponse.dialogResult(result))
        let decoded = try JSONDecoder.winkBridgeDecoder().decode(WinkBridgeResponse.self, from: data)

        guard case let .dialogResult(decodedResult) = decoded else {
            Issue.record("Expected dialog result")
            return
        }
        #expect(decodedResult.targetReceipt == receipt)
        #expect(decodedResult.outcome == result.outcome)
        #expect(decodedResult.details == result.details)
    }
}

private enum LegacyProtocol127Operation: String, Codable {
    case dialogEnterText
    case exactDialogEnterText
}

private struct LegacyProtocol127Handshake: Decodable {
    let supportedOperations: [LegacyProtocol127Operation]
    let enabledOperations: [LegacyProtocol127Operation]
    let hostCapabilities: [String]
}
