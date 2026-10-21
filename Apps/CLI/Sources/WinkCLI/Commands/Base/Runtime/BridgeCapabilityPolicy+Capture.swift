import WinkBridge
import WinkFoundation

extension BridgeCapabilityPolicy {
    static func supportsScreenCaptureKitProcessOwnership(
        for handshake: WinkBridgeHandshakeResponse
    ) -> Bool {
        handshake.supportedOperations.contains(.desktopObservation) &&
            (handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.screenCaptureKitProcessOwnership
            ) == true || handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.screenCaptureKitOwnershipEnforcement
            ) == true)
    }

    static func supportsClassicCaptureWithoutScreenCaptureKit(
        for handshake: WinkBridgeHandshakeResponse
    ) -> Bool {
        handshake.supportedOperations.contains(.desktopObservation) &&
            (handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.classicCaptureWithoutScreenCaptureKit
            ) == true || handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.screenCaptureKitProcessOwnership
            ) == true)
    }

    static func screenCaptureKitReadinessRefusal(
        for handshake: WinkBridgeHandshakeResponse
    ) -> ScreenCaptureKitOwnershipDiagnostic? {
        guard self.supportsScreenCaptureKitProcessOwnership(for: handshake) else { return nil }
        // The old capability is the named compatibility contract for hosts without readiness data.
        if handshake.screenCaptureKitReadiness == nil,
           handshake.hostCapabilities?.contains(WinkBridgeHostCapability.screenCaptureKitOwnershipEnforcement)
           != true {
            return nil
        }
        guard handshake.screenCaptureKitReadiness?.permitsAttempt != true else { return nil }
        return handshake.screenCaptureKitReadiness?.refusal ?? ScreenCaptureKitReadiness(state: .unknown).refusal
    }
}
