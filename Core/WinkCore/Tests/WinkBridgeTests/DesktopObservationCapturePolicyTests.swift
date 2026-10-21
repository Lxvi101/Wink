import WinkAutomationKit
import Testing
@testable import WinkBridge

@MainActor
struct DesktopObservationCapturePolicyTests {
    @Test
    func `Bridge auto screen policy preserves explicit foreground non-screen and ownerless requests`() {
        let hostIdentity = WinkBridgeHostIdentity(
            processIdentifier: 42,
            processStartIdentity: 84,
            bundleIdentifier: nil,
            bundleShortVersion: nil,
            bundleVersion: nil,
            codeSignatureHash: nil)
        let ownerReceipt = ScreenCaptureKitOwnerLease.OwnerReceipt(
            processIdentifier: 42,
            processStartIdentity: 84)
        let differentProcessReceipt = ScreenCaptureKitOwnerLease.OwnerReceipt(
            processIdentifier: 43,
            processStartIdentity: 84)
        let differentGenerationReceipt = ScreenCaptureKitOwnerLease.OwnerReceipt(
            processIdentifier: 42,
            processStartIdentity: 85)
        let backgroundScreen = DesktopObservationRequest(
            target: .screen(index: 0),
            capture: .init(engine: .auto, focus: .background))
        #expect(WinkBridgeServer.desktopObservationPrefersModernFirstAutomaticCapture(
            backgroundScreen,
            hostRegisteredScreenCaptureKitOwnership: true,
            hostIdentity: hostIdentity,
            currentScreenCaptureKitOwnerReceipt: ownerReceipt))
        #expect(!WinkBridgeServer.desktopObservationPrefersModernFirstAutomaticCapture(
            backgroundScreen,
            hostRegisteredScreenCaptureKitOwnership: false,
            hostIdentity: hostIdentity,
            currentScreenCaptureKitOwnerReceipt: ownerReceipt))
        #expect(!WinkBridgeServer.desktopObservationPrefersModernFirstAutomaticCapture(
            backgroundScreen,
            hostRegisteredScreenCaptureKitOwnership: true,
            hostIdentity: hostIdentity,
            currentScreenCaptureKitOwnerReceipt: nil))
        #expect(!WinkBridgeServer.desktopObservationPrefersModernFirstAutomaticCapture(
            backgroundScreen,
            hostRegisteredScreenCaptureKitOwnership: true,
            hostIdentity: hostIdentity,
            currentScreenCaptureKitOwnerReceipt: differentProcessReceipt))
        #expect(!WinkBridgeServer.desktopObservationPrefersModernFirstAutomaticCapture(
            backgroundScreen,
            hostRegisteredScreenCaptureKitOwnership: true,
            hostIdentity: hostIdentity,
            currentScreenCaptureKitOwnerReceipt: differentGenerationReceipt))

        for engine in [CaptureEnginePreference.legacy, .modern] {
            let explicit = DesktopObservationRequest(
                target: .screen(index: 0),
                capture: .init(engine: engine, focus: .background))
            #expect(!WinkBridgeServer.desktopObservationPrefersModernFirstAutomaticCapture(
                explicit,
                hostRegisteredScreenCaptureKitOwnership: true,
                hostIdentity: hostIdentity,
                currentScreenCaptureKitOwnerReceipt: ownerReceipt))
        }

        let foreground = DesktopObservationRequest(
            target: .screen(index: 0),
            capture: .init(engine: .auto, focus: .foreground))
        let window = DesktopObservationRequest(
            target: .windowID(42),
            capture: .init(engine: .auto, focus: .background))
        #expect(!WinkBridgeServer.desktopObservationPrefersModernFirstAutomaticCapture(
            foreground,
            hostRegisteredScreenCaptureKitOwnership: true,
            hostIdentity: hostIdentity,
            currentScreenCaptureKitOwnerReceipt: ownerReceipt))
        #expect(!WinkBridgeServer.desktopObservationPrefersModernFirstAutomaticCapture(
            window,
            hostRegisteredScreenCaptureKitOwnership: true,
            hostIdentity: hostIdentity,
            currentScreenCaptureKitOwnerReceipt: ownerReceipt))
    }
}
