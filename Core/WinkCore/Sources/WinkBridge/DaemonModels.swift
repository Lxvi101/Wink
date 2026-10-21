import Foundation
import WinkAutomationKit
import WinkFoundation

public enum WinkDaemonMode: String, Codable, Sendable {
    case auto
    case manual
    case mcp
}

public struct WinkBridgeDaemonStopRequest: Codable, Sendable {
    public let expectedPID: pid_t

    public init(expectedPID: pid_t) {
        self.expectedPID = expectedPID
    }
}

public struct WinkDaemonActivityStatus: Codable, Sendable {
    public let activeRequests: Int
    public let lastActivityAt: Date?
    public let idleTimeoutSeconds: Double?
    public let idleExitAt: Date?

    public init(
        activeRequests: Int,
        lastActivityAt: Date?,
        idleTimeoutSeconds: Double?,
        idleExitAt: Date?)
    {
        self.activeRequests = activeRequests
        self.lastActivityAt = lastActivityAt
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.idleExitAt = idleExitAt
    }
}

public struct WinkDaemonBridgeStatus: Codable, Sendable {
    public let socketPath: String
    public let hostKind: WinkBridgeHostKind
    /// Protocol-1.0-safe operation cases retained for legacy decoders.
    public let allowedOperations: [WinkBridgeOperation]
    /// Complete current capability set as raw names; unknown names are safe for older clients to ignore.
    public let availableOperationNames: [String]?

    public init(
        socketPath: String,
        hostKind: WinkBridgeHostKind,
        allowedOperations: [WinkBridgeOperation],
        availableOperationNames: [String]? = nil)
    {
        self.socketPath = socketPath
        self.hostKind = hostKind
        self.allowedOperations = allowedOperations
        self.availableOperationNames = availableOperationNames
    }
}

public struct WinkDaemonSnapshotStatus: Codable, Sendable {
    public let backend: String
    public let snapshotCount: Int
    public let lastAccessedAt: Date?
    public let storagePath: String

    public init(
        backend: String,
        snapshotCount: Int,
        lastAccessedAt: Date?,
        storagePath: String)
    {
        self.backend = backend
        self.snapshotCount = snapshotCount
        self.lastAccessedAt = lastAccessedAt
        self.storagePath = storagePath
    }
}

public struct WinkDaemonWindowTrackerStatus: Codable, Sendable {
    public let trackedWindows: Int
    public let lastEventAt: Date?
    public let lastPollAt: Date?
    public let axObserverCount: Int
    public let cgPollIntervalMs: Int

    public init(
        trackedWindows: Int,
        lastEventAt: Date?,
        lastPollAt: Date?,
        axObserverCount: Int,
        cgPollIntervalMs: Int)
    {
        self.trackedWindows = trackedWindows
        self.lastEventAt = lastEventAt
        self.lastPollAt = lastPollAt
        self.axObserverCount = axObserverCount
        self.cgPollIntervalMs = cgPollIntervalMs
    }
}

public struct WinkDaemonStatus: Codable, Sendable {
    /// Set by CLI status observation after authentication, never used as host authority.
    public var trustMode: WinkBridgeTrustMode?
    public let running: Bool
    public let pid: pid_t?
    public let startedAt: Date?
    public let mode: WinkDaemonMode?
    public let bridge: WinkDaemonBridgeStatus?
    public let permissions: PermissionsStatus?
    public let snapshots: WinkDaemonSnapshotStatus?
    public let windowTracker: WinkDaemonWindowTrackerStatus?
    public let browser: WinkBridgeBrowserStatus?
    public let activity: WinkDaemonActivityStatus?
    public let supportsConditionalStop: Bool?

    public init(
        running: Bool,
        pid: pid_t? = nil,
        startedAt: Date? = nil,
        mode: WinkDaemonMode? = nil,
        bridge: WinkDaemonBridgeStatus? = nil,
        permissions: PermissionsStatus? = nil,
        snapshots: WinkDaemonSnapshotStatus? = nil,
        windowTracker: WinkDaemonWindowTrackerStatus? = nil,
        browser: WinkBridgeBrowserStatus? = nil,
        activity: WinkDaemonActivityStatus? = nil,
        supportsConditionalStop: Bool? = nil)
    {
        self.running = running
        self.pid = pid
        self.startedAt = startedAt
        self.mode = mode
        self.bridge = bridge
        self.permissions = permissions
        self.snapshots = snapshots
        self.windowTracker = windowTracker
        self.browser = browser
        self.activity = activity
        self.supportsConditionalStop = supportsConditionalStop
    }
}

@MainActor
public protocol WinkDaemonControlProviding: AnyObject, Sendable {
    func daemonStatus() async -> WinkDaemonStatus
    func requestStop() async -> Bool
    func recordActivityStart(operation: WinkBridgeOperation) async
    func recordActivityEnd(operation: WinkBridgeOperation) async
}

@MainActor
extension WinkDaemonControlProviding {
    public func recordActivityStart(operation _: WinkBridgeOperation) async {}
    public func recordActivityEnd(operation _: WinkBridgeOperation) async {}
}

@MainActor
public protocol WinkConditionalDaemonControlProviding: WinkDaemonControlProviding {
    func requestStop(expectedPID: pid_t) async -> Bool
    func admitActivity(operation: WinkBridgeOperation) async -> Bool
}
