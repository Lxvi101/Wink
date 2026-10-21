import WinkAutomationKit
import WinkFoundation

/// Narrow service surface required by `WinkBridgeServer`.
///
/// Bridge hosts (Wink.app, ClawdBot.app, or in-process callers) provide concrete
/// implementations for these services.
@MainActor
public protocol WinkBridgeServiceProviding: AnyObject, Sendable {
    var permissions: PermissionsService { get }
    var screenCapture: any ScreenCaptureServiceProtocol { get }
    var automation: any UIAutomationServiceProtocol { get }
    var windows: any WindowManagementServiceProtocol { get }
    var applications: any ApplicationServiceProtocol { get }
    var menu: any MenuServiceProtocol { get }
    var dock: any DockServiceProtocol { get }
    var dialogs: any DialogServiceProtocol { get }
    var snapshots: any SnapshotManagerProtocol { get }
    var desktopObservation: any DesktopObservationServiceProtocol { get }
    var supportsDesktopObservationCaptureEngine: Bool { get }
    var supportsScreenCaptureKitProcessOwnership: Bool { get }
    var supportsClassicCaptureWithoutScreenCaptureKit: Bool { get }
    var browserSessionBootstrapProvider: (any WinkBridgeBrowserSessionBootstrapProviding)? { get }

    /// Whether the concrete native service owns the lane for this exact operation.
    /// Test doubles and older hosts default to Bridge-owned conservative coordination.
    func ownsDesktopOperationLane(for operation: WinkBridgeOperation) -> Bool

    func browserStatus(channel: String?) async throws -> WinkBridgeBrowserStatus
    func browserConnect(channel: String?) async throws -> WinkBridgeBrowserStatus
    func browserConnect(channel: String?, browserURL: String?) async throws -> WinkBridgeBrowserStatus
    func browserDisconnect() async throws
    func browserExecute(_ request: WinkBridgeBrowserExecuteRequest) async throws
        -> WinkBridgeBrowserToolResponse
    func browserExecute(
        _ request: WinkBridgeBrowserExecuteRequest,
        expectedConnectionReceipt: WinkBridgeBrowserConnectionReceipt) async throws
        -> WinkBridgeBrowserExecutionResult
}

@MainActor
public protocol WinkBridgeBrowserConnectionResultProviding: WinkBridgeServiceProviding {
    var supportsNativeBrowserConnectionBinding: Bool { get }

    func browserConnectResult(
        channel: String?,
        browserURL: String?) async throws -> DesktopActionResult<WinkBridgeBrowserStatus>
}

extension WinkBridgeBrowserConnectionResultProviding {
    public var supportsNativeBrowserConnectionBinding: Bool {
        false
    }
}

@MainActor
extension WinkBridgeServiceProviding {
    public var supportsDesktopObservationCaptureEngine: Bool {
        self.screenCapture is any EngineAwareScreenCaptureServiceProtocol
    }

    public var supportsScreenCaptureKitProcessOwnership: Bool {
        false
    }

    public var supportsClassicCaptureWithoutScreenCaptureKit: Bool {
        false
    }

    public var browserSessionBootstrapProvider: (any WinkBridgeBrowserSessionBootstrapProviding)? {
        nil
    }

    public func ownsDesktopOperationLane(for _: WinkBridgeOperation) -> Bool {
        false
    }

    public func browserStatus(channel _: String?) async throws -> WinkBridgeBrowserStatus {
        throw WinkBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "Browser MCP is not supported by this bridge host")
    }

    public func browserConnect(channel _: String?) async throws -> WinkBridgeBrowserStatus {
        throw WinkBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "Browser MCP is not supported by this bridge host")
    }

    public func browserConnect(channel: String?, browserURL: String?) async throws -> WinkBridgeBrowserStatus {
        guard browserURL == nil else {
            throw WinkBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "This bridge host cannot carry an exact browser endpoint")
        }
        return try await self.browserConnect(channel: channel)
    }

    public func browserDisconnect() async throws {
        throw WinkBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "Browser MCP is not supported by this bridge host")
    }

    public func browserExecute(_: WinkBridgeBrowserExecuteRequest) async throws
    -> WinkBridgeBrowserToolResponse {
        throw WinkBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "Browser MCP is not supported by this bridge host")
    }

    public func browserExecute(
        _: WinkBridgeBrowserExecuteRequest,
        expectedConnectionReceipt _: WinkBridgeBrowserConnectionReceipt) async throws
        -> WinkBridgeBrowserExecutionResult
    {
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .operationUnsupported,
            message: "This Bridge browser provider cannot bind execution to an exact connection receipt.",
            hint: "Update the runtime host before retrying target-attested browser execution.")
    }
}
