import Darwin
import Foundation
import WinkAutomationKit
import WinkAutomationKitTestSupport
import WinkBridgeTestSupport
import WinkFoundation
import WinkFoundationTestSupport
import Testing
@testable import WinkBridge
@testable import WinkCore

@Suite(.serialized)
struct ProducerBoundSnapshotBridgeTests {
    @Test
    @MainActor
    func `current offer exposes signed producer ownership independently`() async throws {
        let snapshots = InMemorySnapshotManager()
        let ordinary = try await snapshots.createSnapshot()
        let pending = try await snapshots.createSnapshot(pendingAt: Date())
        let explicit = try await snapshots.createExplicitSnapshot()
        let socketPath = "/tmp/wink-producer-snapshot-\(UUID().uuidString).sock"
        let server = WinkBridgeServer(
            services: WinkServices(snapshotManager: snapshots),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = WinkBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        let handshake = try await client.handshake(client: Self.identity)
        #expect(handshake.negotiatedVersion == WinkBridgeConstants.protocolVersion)
        #expect(handshake.supportedOperations.contains(.ownsSnapshot))
        #expect(handshake.hostCapabilities?.contains(
            WinkBridgeHostCapability.producerBoundSnapshotReferences) == true)
        #expect(handshake.hostCapabilities?.contains(
            WinkBridgeHostCapability.targetedClickAccessibilityValueDelivery) == true)

        for snapshotID in [ordinary, pending, explicit] {
            #expect(try await client.ownsSnapshot(snapshotId: snapshotID))
            let receipt = try #require(await client.lastOperationReceipt())
            #expect(receipt.payload.operation == .ownsSnapshot)
            #expect(receipt.payload.outcome == nil)
        }
        #expect(try await !client.ownsSnapshot(snapshotId: SnapshotReferenceFixtures.id(99)))
        try await snapshots.cleanSnapshot(snapshotId: ordinary)
        #expect(try await !client.ownsSnapshot(snapshotId: ordinary))
        await host.stop()
    }

    @Test
    @MainActor
    func `legacy 1 34 client offer omits only new same-minor operations and capabilities`() async throws {
        let socketPath = "/tmp/wink-legacy-134-snapshot-\(UUID().uuidString).sock"
        let server = WinkBridgeServer(
            services: WinkServices(snapshotManager: InMemorySnapshotManager()),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = WinkBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        let response = try await client.send(.handshake(.init(
            protocolVersion: .init(major: 1, minor: 34),
            client: Self.identity,
            operationClientInstanceID: client.operationClientInstanceID,
            clientCapabilities: nil)))
        let handshake: WinkBridgeHandshakeResponse
        guard case let .handshake(value) = response else {
            Issue.record("Expected handshake response")
            return
        }
        handshake = value
        #expect(!handshake.supportedOperations.contains(.ownsSnapshot))
        #expect(handshake.enabledOperations?.contains(.ownsSnapshot) != true)
        #expect(handshake.hostCapabilities?.contains(
            WinkBridgeHostCapability.producerBoundSnapshotReferences) != true)
        #expect(handshake.hostCapabilities?.contains(
            WinkBridgeHostCapability.targetedClickAccessibilityValueDelivery) != true)
        // #622 remains independent at the already-shipped 1.34 floor.
        #expect(handshake.hostCapabilities?.contains(
            WinkBridgeHostCapability.nativeBrowserConnectionBinding) == true)
        await host.stop()
    }

    @Test
    @MainActor
    func `same minor browser snapshot and value capabilities negotiate independently`() async throws {
        let browserOnlyServer = WinkBridgeServer(
            services: WinkServices(snapshotManager: InMemorySnapshotManager()),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let browserOnly = try await Self.rawLiveHandshake(
            server: browserOnlyServer,
            clientCapabilities: [])
        #expect(browserOnly.hostCapabilities?.contains(
            WinkBridgeHostCapability.nativeBrowserConnectionBinding) == true)
        #expect(browserOnly.hostCapabilities?.contains(
            WinkBridgeHostCapability.producerBoundSnapshotReferences) != true)
        #expect(browserOnly.hostCapabilities?.contains(
            WinkBridgeHostCapability.targetedClickAccessibilityValueDelivery) != true)

        let snapshotOnlyServer = WinkBridgeServer(
            services: NonBrowserCapabilityServices(
                base: StubServices(snapshots: InMemorySnapshotManager())),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let snapshotOnly = try await Self.rawLiveHandshake(
            server: snapshotOnlyServer,
            clientCapabilities: [WinkBridgeClientCapability.producerBoundSnapshotReferences])
        #expect(snapshotOnly.hostCapabilities?.contains(
            WinkBridgeHostCapability.nativeBrowserConnectionBinding) != true)
        #expect(snapshotOnly.hostCapabilities?.contains(
            WinkBridgeHostCapability.producerBoundSnapshotReferences) == true)
        #expect(snapshotOnly.hostCapabilities?.contains(
            WinkBridgeHostCapability.targetedClickAccessibilityValueDelivery) != true)

        let valueOnlySnapshots = SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager(),
            supportsProducerBoundSnapshotReferences: false)
        let valueOnlyBase = StubServices(snapshots: valueOnlySnapshots)
        valueOnlyBase.automationStub.supportsTargetedClickAccessibilityValueDelivery = true
        let valueOnlyServices = NonBrowserCapabilityServices(base: valueOnlyBase)
        let valueOnlyServer = WinkBridgeServer(
            services: valueOnlyServices,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let valueOnly = try await Self.rawLiveHandshake(
            server: valueOnlyServer,
            clientCapabilities: [WinkBridgeClientCapability.targetedClickAccessibilityValueDelivery])
        #expect(valueOnly.hostCapabilities?.contains(
            WinkBridgeHostCapability.nativeBrowserConnectionBinding) != true)
        #expect(valueOnly.hostCapabilities?.contains(
            WinkBridgeHostCapability.producerBoundSnapshotReferences) != true)
        #expect(valueOnly.hostCapabilities?.contains(
            WinkBridgeHostCapability.targetedClickAccessibilityValueDelivery) == true)
    }

    @Test
    @MainActor
    func `new client refuses old same minor snapshot creation before a second wire request`() async throws {
        let featureVersion = WinkBridgeConstants.producerBoundSnapshotReferencesVersion
        let snapshots = SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager(),
            supportsProducerBoundSnapshotReferences: false)
        let server = WinkBridgeServer(
            services: StubServices(snapshots: snapshots),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: featureVersion...featureVersion)
        let socketPath = "/tmp/wink-old-134-create-\(UUID().uuidString).sock"
        let host = WinkBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        let handshake = try await client.handshake(client: Self.identity)
        #expect(handshake.negotiatedVersion == featureVersion)
        #expect(handshake.hostCapabilities?.contains(
            WinkBridgeHostCapability.producerBoundSnapshotReferences) != true)

        await #expect(throws: WinkBridgeErrorEnvelope.self) {
            _ = try await client.createSnapshot()
        }
        #expect(snapshots.createCalls.isEmpty)
        await host.stop()
    }

    @Test
    @MainActor
    func `current client refuses snapshot publication without breaking legacy server carriage`() async throws {
        let snapshots = SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager(),
            supportsProducerBoundSnapshotReferences: false)
        let server = WinkBridgeServer(
            services: StubServices(snapshots: snapshots),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let socketPath = "/tmp/wink-old-134-publication-\(UUID().uuidString).sock"
        let host = WinkBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        let handshake = try await client.handshake(client: Self.identity)
        #expect(handshake.hostCapabilities?.contains(
            WinkBridgeHostCapability.producerBoundSnapshotReferences) != true)

        let snapshotID = SnapshotReferenceFixtures.first.rawValue
        let detection = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "fixture"))
        let screenshot = SnapshotScreenshotRequest(
            snapshotId: snapshotID,
            screenshotPath: "/tmp/unused.png",
            applicationBundleId: nil,
            applicationProcessId: nil,
            applicationName: nil,
            windowTitle: nil,
            windowBounds: nil)
        let publication = SnapshotObservationPublicationRequest(
            screenshot: screenshot,
            detectionResult: detection,
            annotatedScreenshotPath: nil)

        let requests: [WinkBridgeRequest] = [
            .createSnapshot(.init()),
            .storeDetectionResult(.init(snapshotId: snapshotID, result: detection)),
            .storeScreenshot(.init(screenshot)),
            .storeObservationSnapshot(.init(publication)),
            .storeAnnotatedScreenshot(.init(
                snapshotId: snapshotID,
                annotatedScreenshotPath: "/tmp/unused-annotated.png")),
        ]
        let allCreateOrPublish = requests.allSatisfy(\.createsOrPublishesSnapshotState)
        let allRemainLegacyServerCompatible = requests.allSatisfy {
            !$0.requiresProducerBoundSnapshotReferences
        }
        #expect(allCreateOrPublish)
        #expect(allRemainLegacyServerCompatible)

        for request in requests {
            do {
                _ = try await client.send(request)
                Issue.record("Expected snapshot publication capability refusal for \(request.operation.rawValue)")
            } catch let envelope as WinkBridgeErrorEnvelope {
                #expect(envelope.code == .operationNotSupported)
            }
        }

        #expect(snapshots.createCalls.isEmpty)
        #expect(try await snapshots.listSnapshots().isEmpty)
        await host.stop()
    }

    @Test
    @MainActor
    func `new client refuses explicit value delivery policy on old same minor host before click`() async throws {
        let featureVersion = WinkBridgeConstants.targetedClickAccessibilityValueDeliveryVersion
        let services = StubServices(snapshots: InMemorySnapshotManager())
        let server = WinkBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: featureVersion...featureVersion)
        let socketPath = "/tmp/wink-old-134-click-policy-\(UUID().uuidString).sock"
        let host = WinkBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        let handshake = try await client.handshake(client: Self.identity)
        #expect(handshake.negotiatedVersion == featureVersion)
        #expect(handshake.hostCapabilities?.contains(
            WinkBridgeHostCapability.targetedClickAccessibilityValueDelivery) != true)

        let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 7)
        do {
            _ = try await client.clickWithOutcome(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue,
                expectedProcessIdentity: identity,
                allowsAccessibilityValueDelivery: false)
            Issue.record("Expected an old-host policy refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.message.contains("accessibility-value click policy"))
        }
        #expect(services.automationStub.lastClick == nil)
        await host.stop()
    }

    @Test
    @MainActor
    func `client rejects noncanonical references from a capability claiming host`() async throws {
        let snapshots = SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager(),
            createdSnapshotReferenceOverride: "1787675983803-1514")
        let server = WinkBridgeServer(
            services: StubServices(snapshots: snapshots),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let socketPath = "/tmp/wink-hostile-snapshot-reference-\(UUID().uuidString).sock"
        let host = WinkBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        _ = try await client.handshake(client: Self.identity)

        do {
            _ = try await client.createSnapshot()
            Issue.record("Expected the client to reject a noncanonical snapshot reference")
        } catch let envelope as WinkBridgeErrorEnvelope {
            #expect(envelope.code == .invalidRequest)
            #expect(envelope.message.contains("non-canonical"))
        }
        #expect(snapshots.createCalls.count == 1)
        await host.stop()
    }

    @Test
    @MainActor
    func `provider claims and protocol floor gate the two additions independently`() async throws {
        let wrappedSnapshots = SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager(),
            supportsProducerBoundSnapshotReferences: false)
        let legacyServer = WinkBridgeServer(
            services: StubServices(snapshots: wrappedSnapshots),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let legacy = try await Self.liveHandshake(server: legacyServer, version: .init(major: 1, minor: 34))
        #expect(!legacy.supportedOperations.contains(.ownsSnapshot))
        #expect(legacy.hostCapabilities?.contains(
            WinkBridgeHostCapability.producerBoundSnapshotReferences) != true)
        #expect(legacy.hostCapabilities?.contains(
            WinkBridgeHostCapability.targetedClickAccessibilityValueDelivery) != true)

        let currentServer = WinkBridgeServer(
            services: WinkServices(snapshotManager: InMemorySnapshotManager()),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let downgraded = try await Self.liveHandshake(server: currentServer, version: .init(major: 1, minor: 33))
        #expect(!downgraded.supportedOperations.contains(.ownsSnapshot))
        #expect(downgraded.hostCapabilities?.contains(
            WinkBridgeHostCapability.producerBoundSnapshotReferences) != true)
        #expect(downgraded.hostCapabilities?.contains(
            WinkBridgeHostCapability.targetedClickAccessibilityValueDelivery) != true)
        #expect(downgraded.hostCapabilities?.contains(
            WinkBridgeHostCapability.nativeBrowserConnectionBinding) != true)
    }

    @Test
    func `new optional client offer decodes in a legacy handshake payload`() throws {
        let payload = WinkBridgeHandshake(
            protocolVersion: .init(major: 1, minor: 34),
            client: Self.identity,
            operationClientInstanceID: UUID(),
            clientCapabilities: [
                WinkBridgeClientCapability.producerBoundSnapshotReferences,
                WinkBridgeClientCapability.targetedClickAccessibilityValueDelivery,
            ])
        let legacy = try JSONDecoder.winkBridgeDecoder().decode(
            LegacyHandshakePayload.self,
            from: JSONEncoder.winkBridgeEncoder().encode(payload))
        #expect(legacy.protocolVersion == payload.protocolVersion)
        #expect(legacy.client.processIdentifier == payload.client.processIdentifier)
    }

    @Test
    func `direct client refuses receiptless capability claims before a second request`() async throws {
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 34),
            supportedOperations: [.ownsSnapshot, .targetedClick],
            hostCapabilities: [
                WinkBridgeHostCapability.producerBoundSnapshotReferences,
                WinkBridgeHostCapability.targetedClickAccessibilityValueDelivery,
            ])
        let peer = try ScriptedBridgePeer(responses: [.handshake(handshake)])
        let client = WinkBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)

        await #expect(throws: WinkBridgeErrorEnvelope.self) {
            _ = try await client.handshake(client: Self.identity, protocolVersion: .init(major: 1, minor: 34))
        }
        #expect(await peer.requests.count == 1)
        await peer.waitUntilFinished()
    }

    @Test
    @MainActor
    func `hostile missing and contradictory sessions refuse before snapshot or click providers`() throws {
        let snapshots = SnapshotMutationRecordingManager(wrapping: InMemorySnapshotManager())
        let services = StubServices(snapshots: snapshots)
        let server = WinkBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let snapshotID = SnapshotReferenceFixtures.first.rawValue
        let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 7)
        let owns = WinkBridgeRequest.ownsSnapshot(.init(snapshotId: snapshotID))
        let click = WinkBridgeRequest.targetedClick(.init(
            target: .elementId("field"),
            clickType: .single,
            snapshotId: snapshotID,
            targetProcessIdentifier: identity.processIdentifier,
            expectedProcessIdentity: identity,
            allowsAccessibilityValueDelivery: true))
        let permissions = PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
        let enabled = server.effectiveAllowedOperations(permissions: permissions)
        let hostileSessions = [
            WinkBridgeNegotiatedSessionCapabilities(
                protocolVersion: .init(major: 1, minor: 34),
                statelessClickVariants: true,
                exactWindowHeldPointerLifecycle: true,
                producerBoundSnapshotReferences: false,
                targetedClickAccessibilityValueDelivery: false),
            WinkBridgeNegotiatedSessionCapabilities(
                protocolVersion: .init(major: 1, minor: 33),
                statelessClickVariants: true,
                exactWindowHeldPointerLifecycle: true,
                producerBoundSnapshotReferences: true,
                targetedClickAccessibilityValueDelivery: true),
        ]

        for session in hostileSessions {
            for request in [owns, click] {
                #expect(throws: WinkBridgeErrorEnvelope.self) {
                    try WinkBridgeRequestContext.$negotiatedSessionCapabilities.withValue(session) {
                        try server.validateOperationAccess(
                            for: request,
                            permissions: permissions,
                            effectiveOps: enabled)
                    }
                }
            }
        }
        #expect(snapshots.ownsCalls.isEmpty)
        #expect(services.automationStub.lastClick == nil)
    }

    @Test
    @MainActor
    func `omitted legacy click policy preserves value delivery on a current host`() async throws {
        let services = StubServices(snapshots: InMemorySnapshotManager())
        services.automationStub.supportsTargetedClickAccessibilityValueDelivery = true
        services.automationStub.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            unitCount: .one)
        let server = WinkBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 7)
        let request = WinkBridgeRequest.targetedClick(.init(
            target: .elementId("field"),
            clickType: .single,
            snapshotId: SnapshotReferenceFixtures.first.rawValue,
            targetProcessIdentifier: identity.processIdentifier,
            expectedProcessIdentity: identity))
        let legacySession = WinkBridgeNegotiatedSessionCapabilities(
            protocolVersion: .init(major: 1, minor: 34),
            statelessClickVariants: true,
            exactWindowHeldPointerLifecycle: true)
        let permissions = PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)

        let handled = try await WinkBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await WinkBridgeRequestContext.$negotiatedSessionCapabilities.withValue(legacySession) {
                try await server.handleAuthorized(request, peer: nil, permissions: permissions)
            }
        }

        guard case .ok = handled.response else {
            Issue.record("Expected legacy targeted click success")
            return
        }
        #expect(handled.outcome?.delivery?.mechanism == .accessibilityValue)
        #expect(services.automationStub.lastAllowsAccessibilityValueDelivery == true)
    }

    @Test
    @MainActor
    func `explicit value policy without pinned identity refuses before click provider`() async throws {
        let services = StubServices(snapshots: InMemorySnapshotManager())
        services.automationStub.supportsTargetedClickAccessibilityValueDelivery = true
        let server = WinkBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let permissions = PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)

        for policy in [false, true] {
            do {
                _ = try await WinkBridgeRequestContext.$negotiatedSessionCapabilities.withValue(.current) {
                    try await server.handleAuthorized(
                        .targetedClick(.init(
                            target: .elementId("field"),
                            clickType: .single,
                            snapshotId: SnapshotReferenceFixtures.first.rawValue,
                            targetProcessIdentifier: 42,
                            allowsAccessibilityValueDelivery: policy)),
                        peer: nil,
                        permissions: permissions)
                }
                Issue.record("Expected explicit policy \(policy) without a pinned identity to be refused")
            } catch let error as WinkBridgeErrorEnvelope {
                #expect(error.code == .invalidRequest)
            }
        }

        #expect(services.automationStub.lastClick == nil)
        #expect(services.automationStub.lastProcessTargetedClick == nil)
        #expect(services.automationStub.lastAllowsAccessibilityValueDelivery == nil)
    }

    @Test
    @MainActor
    func `malformed owns and policy blind value provider refuse before service entry`() async throws {
        let snapshots = SnapshotMutationRecordingManager(wrapping: InMemorySnapshotManager())
        let services = StubServices(snapshots: snapshots)
        let server = WinkBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let permissions = PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)

        await #expect(throws: WinkBridgeErrorEnvelope.self) {
            _ = try await WinkBridgeRequestContext.$negotiatedSessionCapabilities.withValue(.current) {
                try await server.handleAuthorized(
                    .ownsSnapshot(.init(snapshotId: "snapshot-1")),
                    peer: nil,
                    permissions: permissions)
            }
        }
        #expect(snapshots.ownsCalls.isEmpty)

        let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 7)
        await #expect(throws: (any Error).self) {
            _ = try await WinkBridgeRequestContext.$negotiatedSessionCapabilities.withValue(.current) {
                try await server.handleAuthorized(
                    .targetedClick(.init(
                        target: .elementId("field"),
                        clickType: .single,
                        snapshotId: SnapshotReferenceFixtures.first.rawValue,
                        targetProcessIdentifier: identity.processIdentifier,
                        expectedProcessIdentity: identity,
                        allowsAccessibilityValueDelivery: false)),
                    peer: nil,
                    permissions: permissions)
            }
        }
        #expect(services.automationStub.lastClick == nil)
    }

    @MainActor
    private static func liveHandshake(
        server: WinkBridgeServer,
        version: WinkBridgeProtocolVersion) async throws -> WinkBridgeHandshakeResponse
    {
        let socketPath = "/tmp/wink-capability-matrix-\(UUID().uuidString).sock"
        let host = WinkBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        do {
            let handshake = try await client.handshake(client: Self.identity, protocolVersion: version)
            await host.stop()
            return handshake
        } catch {
            await host.stop()
            throw error
        }
    }

    @MainActor
    private static func rawLiveHandshake(
        server: WinkBridgeServer,
        clientCapabilities: [String]) async throws -> WinkBridgeHandshakeResponse
    {
        let socketPath = "/tmp/wink-raw-capability-matrix-\(UUID().uuidString).sock"
        let host = WinkBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        do {
            let response = try await client.send(.handshake(.init(
                protocolVersion: .init(major: 1, minor: 34),
                client: Self.identity,
                operationClientInstanceID: client.operationClientInstanceID,
                clientCapabilities: clientCapabilities)))
            await host.stop()
            guard case let .handshake(handshake) = response else {
                throw WinkBridgeErrorEnvelope(
                    code: .invalidRequest,
                    message: "Expected capability-matrix handshake response")
            }
            return handshake
        } catch {
            await host.stop()
            throw error
        }
    }

    private static var identity: WinkBridgeClientIdentity {
        WinkBridgeClientIdentity(
            bundleIdentifier: "dev.wink.snapshot-capability-tests",
            teamIdentifier: nil,
            processIdentifier: getpid())
    }
}

private struct LegacyHandshakePayload: Codable {
    let protocolVersion: WinkBridgeProtocolVersion
    let client: WinkBridgeClientIdentity
    let requestedHostKind: WinkBridgeHostKind?
    let operationClientInstanceID: UUID?
    let replacingOperationSessionID: UUID?
}

@MainActor
private final class NonBrowserCapabilityServices: WinkBridgeServiceProviding {
    private let base: StubServices

    init(base: StubServices) {
        self.base = base
    }

    var permissions: PermissionsService {
        self.base.permissions
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.base.screenCapture
    }

    var automation: any UIAutomationServiceProtocol {
        self.base.automation
    }

    var windows: any WindowManagementServiceProtocol {
        self.base.windows
    }

    var applications: any ApplicationServiceProtocol {
        self.base.applications
    }

    var menu: any MenuServiceProtocol {
        self.base.menu
    }

    var dock: any DockServiceProtocol {
        self.base.dock
    }

    var dialogs: any DialogServiceProtocol {
        self.base.dialogs
    }

    var snapshots: any SnapshotManagerProtocol {
        self.base.snapshots
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        self.base.desktopObservation
    }
}
