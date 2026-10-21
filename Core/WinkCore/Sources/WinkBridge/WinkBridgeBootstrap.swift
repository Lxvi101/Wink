import Foundation
import WinkAutomationKit

@MainActor
public enum WinkBridgeBootstrap {
    struct HostConfiguration {
        let hostKind: WinkBridgeHostKind
        let socketPath: String
        let allowlistedTeams: Set<String>
        let allowlistedBundles: Set<String>
        let daemonControl: (any WinkDaemonControlProviding)?
        let automationActivityObserver: (@Sendable (pid_t) -> Void)?
        let allowedOperations: Set<WinkBridgeOperation>
        let hostIdentity: WinkBridgeHostIdentity?
        let hostCapabilities: Set<String>
        let desktopMutationWatermarkStore: DesktopMutationWatermarkStore
        let maxMessageBytes: Int
        let requestTimeoutSec: TimeInterval
        let requestDrainTimeoutSec: TimeInterval
        let screenCaptureKitOwnershipPreparer: @Sendable () async throws -> Void
    }

    @discardableResult
    public static func startHost(
        services: any WinkBridgeServiceProviding,
        hostKind: WinkBridgeHostKind,
        socketPath: String,
        allowlistedTeams: Set<String>,
        allowlistedBundles: Set<String>,
        daemonControl: (any WinkDaemonControlProviding)? = nil,
        automationActivityObserver: (@Sendable (pid_t) -> Void)? = nil,
        allowedOperations: Set<WinkBridgeOperation> = WinkBridgeOperation.remoteDefaultAllowlist,
        hostIdentity: WinkBridgeHostIdentity? = .current(),
        hostCapabilities: Set<String> = [],
        maxMessageBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10) -> WinkBridgeHost
    {
        let host = self.makeHost(
            services: services,
            configuration: HostConfiguration(
                hostKind: hostKind,
                socketPath: socketPath,
                allowlistedTeams: allowlistedTeams,
                allowlistedBundles: allowlistedBundles,
                daemonControl: daemonControl,
                automationActivityObserver: automationActivityObserver,
                allowedOperations: allowedOperations,
                hostIdentity: hostIdentity,
                hostCapabilities: hostCapabilities,
                desktopMutationWatermarkStore: DesktopMutationWatermarkStore(),
                maxMessageBytes: maxMessageBytes,
                requestTimeoutSec: requestTimeoutSec,
                requestDrainTimeoutSec: 1.0,
                screenCaptureKitOwnershipPreparer: {
                    try await ScreenCaptureKitOwnerLease.awaitCurrentProcessCapabilityPreparation()
                })).host
        Task {
            await host.start()
        }
        return host
    }

    @discardableResult
    public static func startHostChecked(
        services: any WinkBridgeServiceProviding,
        hostKind: WinkBridgeHostKind,
        socketPath: String,
        allowlistedTeams: Set<String>,
        allowlistedBundles: Set<String>,
        daemonControl: (any WinkDaemonControlProviding)? = nil,
        automationActivityObserver: (@Sendable (pid_t) -> Void)? = nil,
        allowedOperations: Set<WinkBridgeOperation> = WinkBridgeOperation.remoteDefaultAllowlist,
        hostIdentity: WinkBridgeHostIdentity? = .current(),
        hostCapabilities: Set<String> = [],
        maxMessageBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10) async throws -> WinkBridgeHost
    {
        let host = self.makeHost(
            services: services,
            configuration: HostConfiguration(
                hostKind: hostKind,
                socketPath: socketPath,
                allowlistedTeams: allowlistedTeams,
                allowlistedBundles: allowlistedBundles,
                daemonControl: daemonControl,
                automationActivityObserver: automationActivityObserver,
                allowedOperations: allowedOperations,
                hostIdentity: hostIdentity,
                hostCapabilities: hostCapabilities,
                desktopMutationWatermarkStore: DesktopMutationWatermarkStore(),
                maxMessageBytes: maxMessageBytes,
                requestTimeoutSec: requestTimeoutSec,
                requestDrainTimeoutSec: 1.0,
                screenCaptureKitOwnershipPreparer: {
                    try await ScreenCaptureKitOwnerLease.awaitCurrentProcessCapabilityPreparation()
                })).host
        try await host.startChecked()
        return host
    }

    static func makeHost(
        services: any WinkBridgeServiceProviding,
        configuration: HostConfiguration) -> (host: WinkBridgeHost, capabilities: Set<String>)
    {
        let server = WinkBridgeServer(
            services: services,
            hostKind: configuration.hostKind,
            allowlistedTeams: configuration.allowlistedTeams,
            allowlistedBundles: configuration.allowlistedBundles,
            allowedOperations: configuration.allowedOperations,
            hostIdentity: configuration.hostIdentity,
            hostCapabilities: configuration.hostCapabilities,
            servingSocketPath: configuration.socketPath,
            daemonControl: configuration.daemonControl,
            desktopMutationWatermarkStore: configuration.desktopMutationWatermarkStore,
            screenCaptureKitOwnershipPreparer: configuration.screenCaptureKitOwnershipPreparer,
            automationActivityObserver: configuration.automationActivityObserver,
            browserSessionBootstrapProvider: services.browserSessionBootstrapProvider)
        let host = WinkBridgeHost(
            socketPath: configuration.socketPath,
            server: server,
            maxMessageBytes: configuration.maxMessageBytes,
            allowedTeamIDs: configuration.allowlistedTeams,
            requestTimeoutSec: configuration.requestTimeoutSec,
            requestDrainTimeoutSec: configuration.requestDrainTimeoutSec)
        return (host, server.hostCapabilities)
    }
}
