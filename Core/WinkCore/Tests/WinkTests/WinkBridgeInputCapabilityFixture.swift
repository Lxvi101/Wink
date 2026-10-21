import CoreGraphics
import Foundation
import WinkAutomationKit
import WinkBridgeTestSupport
import WinkFoundation
import Testing
@testable import WinkBridge

@MainActor
enum BridgeInputCapabilityFixture {
    static func startHost(
        services: any WinkBridgeServiceProviding,
        supportedVersions: ClosedRange<WinkBridgeProtocolVersion>,
        allowedOperations: Set<WinkBridgeOperation>,
        operationLaneCoordinator: DesktopOperationLaneCoordinator = .shared,
        permissions: PermissionsStatus = .init(
            screenRecording: true,
            accessibility: true,
            postEvent: true)) async throws
        -> (host: WinkBridgeHost, client: WinkBridgeClient)
    {
        let socketPath = "/tmp/wink-input-capability-\(UUID().uuidString).sock"
        let server = WinkBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: supportedVersions,
            allowedOperations: allowedOperations,
            desktopOperationLaneCoordinator: operationLaneCoordinator,
            permissionStatusEvaluator: { _ in permissions })
        let host = WinkBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        return (host, TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2))
    }

    static func exactTarget() throws -> (
        exactWindow: UIAutomationTarget.ExactWindow,
        keyboardTarget: ExactWindowKeyboardTarget)
    {
        let generation = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 999_999,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: generation,
            capturedBounds: bounds)
        let focused = FocusedElementIdentity(
            processIdentifier: getpid(),
            windowID: identity.windowID,
            role: "AXTextField",
            identifier: "editor",
            frame: CGRect(x: 30, y: 40, width: 120, height: 30))
        return try (
            UIAutomationTarget.ExactWindow(
                identity: identity,
                bounds: bounds,
                focusedElement: focused),
            ExactWindowKeyboardTarget(
                windowIdentity: identity,
                windowBounds: bounds,
                focusedElement: focused))
    }
}
