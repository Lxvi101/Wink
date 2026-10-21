import CoreGraphics
import Foundation
import WinkAutomationKit
import WinkBridgeTestSupport
import WinkCore
import WinkFoundation
import Testing
@testable import WinkBridge

// This suite intentionally keeps the complete targeted-click wire/permission matrix together.
// swiftlint:disable:next type_body_length
struct WinkBridgeTargetedClickTests {
    private let exactIdentity = WindowMutationIdentity(
        windowID: 42,
        ownerProcessIdentifier: 9001,
        ownerProcessStartIdentity: 1)
    private let exactBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    private static let clientIdentity = WinkBridgeClientIdentity(
        bundleIdentifier: "dev.wink.targeted-click-tests",
        teamIdentifier: nil,
        processIdentifier: getpid())

    @Test
    @MainActor
    func `stateless click payload version and background capability are negotiated separately`() async throws {
        let services = StubServices()
        let server = WinkBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let foregroundRequest = WinkBridgeRequest.click(.init(
            target: .coordinates(.zero),
            clickType: .middle,
            snapshotId: nil))
        let backgroundRequest = WinkBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .triple,
            snapshotId: "snapshot",
            targetProcessIdentifier: self.exactIdentity.ownerProcessIdentifier,
            targetWindowID: self.exactIdentity.windowID,
            expectedWindowIdentity: self.exactIdentity,
            expectedWindowBounds: self.exactBounds))
        let legacy = WinkBridgeNegotiatedSessionCapabilities(
            protocolVersion: .init(major: 1, minor: 29),
            statelessClickVariants: false,
            exactWindowHeldPointerLifecycle: false)
        for request in [foregroundRequest, backgroundRequest] {
            await #expect(throws: WinkBridgeErrorEnvelope.self) {
                _ = try await WinkBridgeRequestContext.$negotiatedSessionCapabilities.withValue(legacy) {
                    try await server.route(request, peer: nil)
                }
            }
        }

        let currentForegroundOnly = WinkBridgeNegotiatedSessionCapabilities(
            protocolVersion: WinkBridgeConstants.protocolVersion,
            statelessClickVariants: false,
            exactWindowHeldPointerLifecycle: true)
        _ = try await WinkBridgeRequestContext.$negotiatedSessionCapabilities.withValue(currentForegroundOnly) {
            try await server.route(foregroundRequest, peer: nil)
        }
        await #expect(throws: WinkBridgeErrorEnvelope.self) {
            _ = try await WinkBridgeRequestContext.$negotiatedSessionCapabilities.withValue(currentForegroundOnly) {
                try await server.route(backgroundRequest, peer: nil)
            }
        }
        #expect(services.automationStub.lastClick?.type == .middle)
        #expect(services.automationStub.lastProcessTargetedClick == nil)
    }

    private static let legacyUnprojectedProtocolVersion = WinkBridgeProtocolVersion(major: 1, minor: 22)
    private static let legacyUnprojectedHandshake = BridgeTestFixtures.handshake(
        negotiatedVersion: Self.legacyUnprojectedProtocolVersion,
        supportedOperations: [.targetedClick])

    private func decode(_ data: Data) throws -> WinkBridgeResponse {
        try JSONDecoder.winkBridgeDecoder().decode(WinkBridgeResponse.self, from: data)
    }

    private func legacyUnprojectedClient(socketPath: String) async throws -> WinkBridgeClient {
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        // Targeted click exists in 1.22, the final version before canonical outcome projection.
        _ = try await client.handshake(
            client: Self.clientIdentity,
            protocolVersion: Self.legacyUnprojectedProtocolVersion)
        return client
    }

    @Test
    @MainActor
    func `stateless click capability requires an attested protocol 1 30 session`() async throws {
        let previous = WinkBridgeProtocolVersion(major: 1, minor: 29)
        let currentServer = WinkBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [])

        #expect(WinkBridgeConstants.statelessClickVariantVersion == .init(major: 1, minor: 30))

        let handshakeRequest = WinkBridgeRequest.handshake(.init(
            protocolVersion: previous,
            client: Self.clientIdentity))
        let response = try await self.decode(currentServer.decodeAndHandle(
            JSONEncoder.winkBridgeEncoder().encode(handshakeRequest),
            peer: nil))
        guard case let .handshake(handshake) = response else {
            Issue.record("Expected legacy handshake response")
            return
        }
        #expect(handshake.negotiatedVersion == previous)
        #expect(handshake.hostCapabilities?.contains(WinkBridgeHostCapability.statelessClickVariants) == false)

        let currentRequest = WinkBridgeRequest.handshake(.init(
            protocolVersion: WinkBridgeConstants.protocolVersion,
            client: Self.clientIdentity))
        let currentResponse = try await self.decode(currentServer.decodeAndHandle(
            JSONEncoder.winkBridgeEncoder().encode(currentRequest),
            peer: nil))
        guard case let .handshake(currentHandshake) = currentResponse else {
            Issue.record("Expected current handshake response")
            return
        }
        #expect(currentHandshake.hostCapabilities?.contains(
            WinkBridgeHostCapability.statelessClickVariants) == false)
    }

    @Test
    @MainActor
    func `protocol 1 29 client refuses middle click before transport or receipt reservation`() async throws {
        let socketPath = "/tmp/wink-bridge-legacy-click-\(UUID().uuidString).sock"
        let previous = WinkBridgeProtocolVersion(major: 1, minor: 29)
        let services = StubServices()
        let server = WinkBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: previous...previous,
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let host = WinkBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity, protocolVersion: previous)

        do {
            _ = try await client.clickWithOutcome(
                target: .elementId("B1"),
                clickType: .middle,
                snapshotId: "snapshot",
                expectedWindowIdentity: self.exactIdentity,
                expectedWindowBounds: self.exactBounds)
            Issue.record("Expected protocol capability refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(services.automationStub.lastProcessTargetedClick == nil)
        #expect(await client.lastOperationReceiptBundle() == nil)
    }

    @Test
    @MainActor
    func `foreground middle click requires protocol 1 30 but not background capability`() async throws {
        let previous = WinkBridgeProtocolVersion(major: 1, minor: 29)
        let legacyServices = StubServices()
        let legacySocket = "/tmp/wink-bridge-legacy-foreground-click-\(UUID().uuidString).sock"
        let legacyServer = WinkBridgeServer(
            services: legacyServices,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: previous...previous,
            allowedOperations: [.click],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let legacyHost = WinkBridgeHost(socketPath: legacySocket, server: legacyServer, allowedTeamIDs: [])
        try await legacyHost.startChecked()
        let legacyClient = TrustedBridgeClientFixture.make(socketPath: legacySocket, requestTimeoutSec: 2)
        _ = try await legacyClient.handshake(client: Self.clientIdentity, protocolVersion: previous)

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await legacyClient.clickWithOutcome(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .middle,
                snapshotId: nil)
        }
        #expect(legacyServices.automationStub.lastClick == nil)
        await legacyHost.stop()

        let currentServices = StubServices()
        currentServices.automationStub.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
        let currentSocket = "/tmp/wink-bridge-current-foreground-click-\(UUID().uuidString).sock"
        let currentServer = WinkBridgeServer(
            services: currentServices,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.click],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let currentHost = WinkBridgeHost(socketPath: currentSocket, server: currentServer, allowedTeamIDs: [])
        try await currentHost.startChecked()
        defer { Task { await currentHost.stop() } }
        let currentClient = TrustedBridgeClientFixture.make(socketPath: currentSocket, requestTimeoutSec: 2)
        let handshake = try await currentClient.handshake(client: Self.clientIdentity)
        #expect(handshake.negotiatedVersion == WinkBridgeConstants.protocolVersion)
        #expect(handshake.hostCapabilities?.contains(WinkBridgeHostCapability.statelessClickVariants) == false)

        _ = try await currentClient.clickWithOutcome(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .middle,
            snapshotId: nil)
        #expect(currentServices.automationStub.lastClick?.type == .middle)
    }

    @Test
    @MainActor
    func `receiptless foreground middle click binds to authenticated protocol 1 30 peer`() async throws {
        let services = StubServices()
        services.automationStub.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
        let server = WinkBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.click],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            },
            processStartIdentityProvider: { $0 == 4242 ? 7 : nil })
        let liveIdentity = WinkBridgeLivePeerIdentity(
            auditToken: Data(repeating: 1, count: 32),
            processIdentifier: 4242,
            processIdentifierVersion: 3,
            effectiveUserIdentifier: getuid(),
            processStartIdentity: 7,
            codeSignatureHash: String(repeating: "a", count: 64))
        let peer = WinkBridgePeer(
            liveIdentity: liveIdentity,
            bundleIdentifier: nil,
            teamIdentifier: nil)
        let handshake = try await server.route(.handshake(.init(
            protocolVersion: WinkBridgeConstants.protocolVersion,
            client: Self.clientIdentity)), peer: peer)
        guard case let .handshake(response) = handshake.response else {
            Issue.record("Expected receiptless current handshake")
            return
        }
        #expect(response.operationSessionAttestation == nil)

        _ = try await server.route(.click(.init(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .middle,
            snapshotId: nil)), peer: peer)
        #expect(services.automationStub.lastClick?.type == .middle)

        let unrelatedPeer = WinkBridgePeer(
            liveIdentity: WinkBridgeLivePeerIdentity(
                auditToken: Data(repeating: 2, count: 32),
                processIdentifier: 4242,
                processIdentifierVersion: 3,
                effectiveUserIdentifier: getuid(),
                processStartIdentity: 7,
                codeSignatureHash: nil),
            bundleIdentifier: nil,
            teamIdentifier: nil)
        await #expect(throws: WinkBridgeErrorEnvelope.self) {
            _ = try await server.route(.click(.init(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .triple,
                snapshotId: nil)), peer: unrelatedPeer)
        }

        let authorityRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wink-receiptless-mode-switch-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: authorityRoot) }
        let authority = try WinkBridgeOperationReceiptAuthority(
            socketPath: authorityRoot.appendingPathComponent("bridge.sock").path)
        let attestedClient = WinkBridgeClientIdentity(
            bundleIdentifier: "dev.wink.receiptless-mode-switch",
            teamIdentifier: nil,
            processIdentifier: liveIdentity.processIdentifier)
        let attestedHandshake = try await WinkBridgeRequestContext.$operationReceiptAuthority.withValue(
            authority)
        {
            try await server.route(.handshake(.init(
                protocolVersion: WinkBridgeConstants.protocolVersion,
                client: attestedClient,
                operationClientInstanceID: UUID())), peer: peer)
        }
        guard case let .handshake(attestedResponse) = attestedHandshake.response else {
            Issue.record("Expected attested current handshake")
            return
        }
        #expect(attestedResponse.operationSessionAttestation != nil)
        #expect(server.receiptlessNegotiations[liveIdentity] == nil)
        await #expect(throws: WinkBridgeErrorEnvelope.self) {
            _ = try await server.route(.click(.init(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .middle,
                snapshotId: nil)), peer: peer)
        }
    }

    @Test
    @MainActor
    func `protocol 1 30 signs exact middle and triple click receipts with truthful units`() async throws {
        let socketPath = "/tmp/wink-bridge-current-click-\(UUID().uuidString).sock"
        let services = StubServices()
        let server = WinkBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let host = WinkBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: Self.clientIdentity)
        #expect(handshake.hostCapabilities?.contains(WinkBridgeHostCapability.statelessClickVariants) == true)
        let signedIdentity = WindowMutationIdentity(
            windowID: self.exactIdentity.windowID,
            ownerProcessIdentifier: self.exactIdentity.ownerProcessIdentifier,
            ownerProcessStartIdentity: self.exactIdentity.ownerProcessStartIdentity,
            capturedBounds: self.exactBounds)

        for (clickType, units) in [(ClickType.middle, 3), (.triple, 7)] {
            services.automationStub.actionOutcome = .dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(units))
            let result = try await client.clickWithOutcome(
                target: .elementId("B1"),
                clickType: clickType,
                snapshotId: "snapshot",
                expectedWindowIdentity: signedIdentity,
                expectedWindowBounds: self.exactBounds)

            #expect(result.outcome?.dispatchState.unitCount?.rawValue == units)
            #expect(result.outcome?.delivery == .init(mechanism: .windowTargetedEvents, mode: .background))
            #expect(result.targetIdentity?.exactWindow?.identity == signedIdentity)
            #expect(services.automationStub.lastProcessTargetedClick?.type == clickType)
            let bundle = try #require(await client.lastOperationReceiptBundle())
            try bundle.validate()
            #expect(bundle.receipt.payload.target == .window(signedIdentity))
            #expect(bundle.receipt.payload.outcome?.dispatchState.unitCount?.rawValue == units)
        }

        let downgraded = try await client.handshake(
            client: Self.clientIdentity,
            protocolVersion: .init(major: 1, minor: 29))
        #expect(downgraded.hostCapabilities?.contains(WinkBridgeHostCapability.statelessClickVariants) == false)
        do {
            _ = try await client.clickWithOutcome(
                target: .elementId("B1"),
                clickType: .middle,
                snapshotId: "snapshot",
                expectedWindowIdentity: signedIdentity,
                expectedWindowBounds: self.exactBounds)
            Issue.record("Expected downgraded client refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(services.automationStub.lastProcessTargetedClick?.type == .triple)
    }

    @Test
    @MainActor
    func `signed middle click preserves post-dispatch indeterminacy and exact target`() async throws {
        let socketPath = "/tmp/wink-bridge-indeterminate-click-\(UUID().uuidString).sock"
        let identity = WindowMutationIdentity(
            windowID: self.exactIdentity.windowID,
            ownerProcessIdentifier: self.exactIdentity.ownerProcessIdentifier,
            ownerProcessStartIdentity: self.exactIdentity.ownerProcessStartIdentity,
            capturedBounds: self.exactBounds)
        let services = StubServices()
        services.automationStub.actionOutcome = .indeterminate(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .completionUnknown,
            unitCount: .init(3))
        let server = WinkBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let host = WinkBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)

        do {
            _ = try await client.clickWithOutcome(
                target: .elementId("B1"),
                clickType: .middle,
                snapshotId: "snapshot",
                expectedWindowIdentity: identity,
                expectedWindowBounds: self.exactBounds)
            Issue.record("Expected retry-unsafe indeterminate click")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 3)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.escalation == .observeBeforeRetry)
        }
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.target == .window(identity))
        #expect(bundle.receipt.payload.outcome?.state == .indeterminate)
        #expect(bundle.receipt.payload.outcome?.dispatchState.unitCount?.rawValue == 3)
    }

    @Test
    @MainActor
    func `middle and triple clicks require post event permission before service dispatch`() async throws {
        for clickType in [ClickType.middle, .triple] {
            let services = StubServices()
            let server = WinkBridgeServer(
                services: services,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(screenRecording: false, accessibility: true, postEvent: false)
                })
            let request = WinkBridgeRequest.targetedClick(.init(
                target: .elementId("B1"),
                clickType: clickType,
                snapshotId: "snapshot",
                targetProcessIdentifier: self.exactIdentity.ownerProcessIdentifier,
                targetWindowID: self.exactIdentity.windowID,
                expectedWindowIdentity: self.exactIdentity,
                expectedWindowBounds: self.exactBounds))
            let requestData = try JSONEncoder.winkBridgeEncoder().encode(request)
            let responseData = await WinkBridgeRequestContext.$negotiatedSessionCapabilities.withValue(.current) {
                await server.decodeAndHandle(requestData, peer: nil)
            }
            let response = try self.decode(responseData)

            guard case let .error(envelope) = response else {
                Issue.record("Expected Event Synthesizing refusal")
                continue
            }
            #expect(envelope.code == .permissionDenied)
            #expect(envelope.permission == .postEvent)
            #expect(services.automationStub.lastProcessTargetedClick == nil)
        }
    }

    @Test
    @MainActor
    func `targeted click operation reflects exact window requirement`() {
        let processRequest = WinkBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001))
        let windowRequest = WinkBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001,
            targetWindowID: 42,
            expectedWindowIdentity: self.exactIdentity,
            expectedWindowBounds: self.exactBounds))

        #expect(processRequest.operation == .targetedClick)
        #expect(windowRequest.operation == .exactWindowTargetedClick)

        let services = WinkServices()
        #expect(services.ownsDesktopOperationLane(for: processRequest.operation))
        #expect(services.ownsDesktopOperationLane(for: windowRequest.operation))
    }

    @Test
    @MainActor
    func `exact window click requires exact window allowlist operation`() async throws {
        let request = WinkBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001,
            targetWindowID: 42,
            expectedWindowIdentity: self.exactIdentity,
            expectedWindowBounds: self.exactBounds))
        let requestData = try JSONEncoder.winkBridgeEncoder().encode(request)
        let permissions = PermissionsStatus(
            screenRecording: false,
            accessibility: true,
            appleScript: false,
            postEvent: false)

        let targetedOnly = WinkBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.targetedClick],
            permissionStatusEvaluator: { _ in permissions })
        let rejected = try await self.decode(targetedOnly.decodeAndHandle(requestData, peer: nil))
        guard case let .error(envelope) = rejected else {
            Issue.record("Expected exact-window request to be rejected, got \(rejected)")
            return
        }
        #expect(envelope.code == .operationNotSupported)

        let exactOnly = WinkBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.exactWindowTargetedClick],
            permissionStatusEvaluator: { _ in permissions })
        let accepted = try await self.decode(exactOnly.decodeAndHandle(requestData, peer: nil))
        guard case .ok = accepted else {
            Issue.record("Expected exact-window request to succeed, got \(accepted)")
            return
        }
    }

    @Test
    @MainActor
    func `automation targeted click is forwarded`() async throws {
        let services = StubServices()
        let server = WinkBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })

        let request = WinkBridgeRequest.targetedClick(
            WinkBridgeTargetedClickRequest(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: 9001))
        let requestData = try JSONEncoder.winkBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }

        let lastClick = services.automationStub.lastProcessTargetedClick
        if case let .elementId(id) = lastClick?.target {
            #expect(id == "B1")
        } else {
            Issue.record("Expected element click, got \(String(describing: lastClick?.target))")
        }
        #expect(lastClick?.type == .single)
        #expect(lastClick?.targetProcessIdentifier == 9001)
        #expect(lastClick?.targetWindowID == nil)
    }

    @Test
    @MainActor
    func `automation targeted click preserves exact window`() async throws {
        let services = StubServices()
        let server = WinkBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let request = WinkBridgeRequest.targetedClick(.init(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .single,
            snapshotId: nil,
            targetProcessIdentifier: 9001,
            targetWindowID: 42,
            expectedWindowIdentity: self.exactIdentity,
            expectedWindowBounds: self.exactBounds))

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.winkBridgeEncoder().encode(request),
            peer: nil)
        let response = try self.decode(responseData)

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }
        #expect(services.automationStub.lastProcessTargetedClick?.targetWindowID == 42)
    }

    @Test
    @MainActor
    func `remote targeted click preserves actionable snapshot failures`() async throws {
        let cases: [(WinkError, WinkBridgeErrorCode, WinkBridgeErrorKind, String)] = [
            (.snapshotStale("window moved"), .invalidRequest, .snapshotStale, "window moved"),
            (.snapshotNotFound("expired"), .notFound, .snapshotNotFound, "expired"),
        ]
        for (error, expectedCode, expectedKind, expectedContext) in cases {
            let services = StubServices()
            services.automationStub.targetedClickError = error
            let server = WinkBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true },
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: true,
                        appleScript: false,
                        postEvent: true)
                })
            let request = WinkBridgeRequest.targetedClick(.init(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: 9001,
                targetWindowID: 42,
                expectedWindowIdentity: self.exactIdentity,
                expectedWindowBounds: self.exactBounds))

            let responseData = try await server.decodeAndHandle(
                JSONEncoder.winkBridgeEncoder().encode(request),
                peer: nil)
            guard case let .error(envelope) = try self.decode(responseData) else {
                Issue.record("Expected bridge error for \(error)")
                continue
            }
            #expect(envelope.code == expectedCode)
            #expect(envelope.message == error.localizedDescription)
            #expect(envelope.kind == expectedKind)
            #expect(envelope.context == expectedContext)
        }
    }

    @Test
    @MainActor
    func `remote targeted click restores snapshot errors from bridge envelopes`() async throws {
        let cases: [(WinkError, WinkBridgeErrorCode, WinkBridgeErrorKind, String)] = [
            (.snapshotStale("window moved"), .invalidRequest, .snapshotStale, "window moved"),
            (.snapshotNotFound("expired"), .notFound, .snapshotNotFound, "expired"),
        ]
        for (sourceError, code, expectedKind, context) in cases {
            let peer = try ScriptedBridgePeer(responses: [
                .handshake(Self.legacyUnprojectedHandshake),
                BridgeTestFixtures.errorResponse(
                    code: code,
                    message: sourceError.localizedDescription,
                    details: "\(sourceError)",
                    kind: expectedKind,
                    context: context),
            ])
            let client = try await self.legacyUnprojectedClient(socketPath: peer.socketPath)
            let remote = RemoteUIAutomationService(
                client: client,
                supportsTargetedClicks: true)

            do {
                try await remote.click(
                    target: .elementId("B1"),
                    clickType: .single,
                    snapshotId: "snapshot",
                    targetProcessIdentifier: getpid())
                Issue.record("Expected snapshot error")
            } catch let error as WinkError {
                switch (expectedKind, error) {
                case let (.snapshotStale, .snapshotStale(reason)):
                    #expect(reason == "window moved")
                case let (.snapshotNotFound, .snapshotNotFound(snapshotId)):
                    #expect(snapshotId == "expired")
                default:
                    Issue.record("Unexpected snapshot error: \(error)")
                }
            } catch {
                Issue.record("Unexpected bridge error: \(error)")
            }
            await peer.waitUntilFinished()
        }
    }

    @Test
    @MainActor
    func `real click service preserves stale snapshot diagnostic through bridge facade`() async throws {
        let socketPath = "/tmp/wink-bridge-real-stale-\(UUID().uuidString).sock"
        let services = WinkServices(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly))
        let server = WinkBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let host = WinkBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = try await self.legacyUnprojectedClient(socketPath: socketPath)
        let remote = RemoteUIAutomationService(
            client: client,
            supportsTargetedClicks: true,
            supportsExactWindowTargetedClicks: true)

        do {
            try await remote.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: SnapshotReference.generate().rawValue,
                targetProcessIdentifier: getpid())
            Issue.record("Expected stale snapshot error")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.message.contains("target element is no longer available"))
            #expect(failure.causeDescription == #"snapshotStale("target element is no longer available")"#)
        } catch {
            Issue.record("Unexpected bridge error: \(error)")
        }
    }

    @Test
    @MainActor
    func `targeted click is disabled when both delivery permissions are missing`() async throws {
        let server = WinkBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: false,
                    appleScript: false,
                    postEvent: false)
            })

        let identity = WinkBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)
        let handshakeRequest = WinkBridgeRequest.handshake(
            .init(
                protocolVersion: WinkBridgeConstants.protocolVersion,
                client: identity,
                requestedHostKind: .gui))

        let handshakeData = try JSONEncoder.winkBridgeEncoder().encode(handshakeRequest)
        let handshakeResponseData = await server.decodeAndHandle(handshakeData, peer: nil)
        let handshakeResponse = try self.decode(handshakeResponseData)

        guard case let .handshake(handshake) = handshakeResponse else {
            Issue.record("Expected handshake response, got \(handshakeResponse)")
            return
        }

        #expect(handshake.supportedOperations.contains(.targetedClick))
        #expect(handshake.enabledOperations?.contains(.targetedClick) == false)
        #expect(handshake.supportedOperations.contains(.exactWindowTargetedClick))
        #expect(handshake.enabledOperations?.contains(.exactWindowTargetedClick) == false)
        #expect(handshake.permissionTags[WinkBridgeOperation.targetedClick.rawValue] == [.accessibility])
        #expect(handshake.permissionTags[WinkBridgeOperation.exactWindowTargetedClick.rawValue] == [.accessibility])
        #expect(handshake.supportedOperations.contains(.quitApplication))
        #expect(handshake.enabledOperations?.contains(.quitApplication) == true)
        #expect(handshake.permissionTags[WinkBridgeOperation.quitApplication.rawValue] == [])
        #expect(handshake.enabledOperations?.contains(.hideApplication) == true)
        #expect(handshake.permissionTags[WinkBridgeOperation.hideApplication.rawValue] == [])
    }

    @Test
    @MainActor
    func `targeted click requires accessibility now that delivery is AX-only`() async throws {
        // Positioned pid-routed mouse events mis-deliver at the window corner, so the synthetic
        // path was removed; Event Synthesizing permission alone no longer enables targeted clicks.
        for (accessibility, postEvent, expectedEnabled) in [
            (true, false, true),
            (true, true, true),
            (false, true, false),
        ] {
            let server = WinkBridgeServer(
                services: StubServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { postEvent },
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: accessibility,
                        appleScript: false,
                        postEvent: postEvent)
                })
            let identity = WinkBridgeClientIdentity(
                bundleIdentifier: "dev.peeka.cli",
                teamIdentifier: "TEAMID",
                processIdentifier: getpid(),
                hostname: Host.current().name)
            let request = WinkBridgeRequest.handshake(.init(
                protocolVersion: WinkBridgeConstants.protocolVersion,
                client: identity,
                requestedHostKind: .gui))

            let responseData = try await server.decodeAndHandle(
                JSONEncoder.winkBridgeEncoder().encode(request),
                peer: nil)
            let response = try self.decode(responseData)
            guard case let .handshake(handshake) = response else {
                Issue.record("Expected handshake response, got \(response)")
                continue
            }

            #expect(handshake.enabledOperations?.contains(.targetedClick) == expectedEnabled)
            #expect(handshake.enabledOperations?.contains(.exactWindowTargetedClick) == expectedEnabled)
        }
    }

    @Test
    @MainActor
    func `protocol 1_8 targeted click retains its post event permission contract`() async throws {
        let server = WinkBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let identity = WinkBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)
        let request = WinkBridgeRequest.handshake(.init(
            protocolVersion: .init(major: 1, minor: 8),
            client: identity,
            requestedHostKind: .gui))

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.winkBridgeEncoder().encode(request),
            peer: nil)
        guard case let .handshake(handshake) = try self.decode(responseData) else {
            Issue.record("Expected handshake response")
            return
        }

        #expect(handshake.supportedOperations.contains(.targetedClick))
        #expect(handshake.enabledOperations?.contains(.targetedClick) == false)
        #expect(handshake.permissionTags[WinkBridgeOperation.targetedClick.rawValue] == [.postEvent])
    }

    @Test
    @MainActor
    func `accessibility-only host accepts single element targeted click`() async throws {
        let services = StubServices()
        let server = WinkBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let request = WinkBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001))

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.winkBridgeEncoder().encode(request),
            peer: nil)
        let response = try self.decode(responseData)

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }
        #expect(services.automationStub.lastProcessTargetedClick?.type == .single)
    }

    @Test
    @MainActor
    func `accessibility-only host refuses PID only coordinate targeted clicks`() async throws {
        let services = StubServices()
        let server = WinkBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let payload = WinkBridgeTargetedClickRequest(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .single,
            snapshotId: nil,
            targetProcessIdentifier: 9001)

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.winkBridgeEncoder().encode(WinkBridgeRequest.targetedClick(payload)),
            peer: nil)
        let response = try self.decode(responseData)

        guard case let .error(error) = response else {
            Issue.record("Expected invalid request response, got \(response)")
            return
        }
        #expect(error.code == .invalidRequest)
        #expect(error.message.contains("PID-only"))
        #expect(services.automationStub.lastProcessTargetedClick == nil)
    }

    @Test
    @MainActor
    func `post event only host rejects targeted clicks with accessibility permission`() async throws {
        let requests: [WinkBridgeTargetedClickRequest] = [
            .init(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: 9001),
            .init(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: 9001),
        ]

        for payload in requests {
            let services = StubServices()
            let server = WinkBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true },
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: false,
                        appleScript: false,
                        postEvent: true)
                })
            let responseData = try await server.decodeAndHandle(
                JSONEncoder.winkBridgeEncoder().encode(WinkBridgeRequest.targetedClick(payload)),
                peer: nil)
            let response = try self.decode(responseData)

            guard case let .error(envelope) = response else {
                Issue.record("Expected permission error, got \(response)")
                continue
            }
            #expect(envelope.code == .permissionDenied)
            #expect(envelope.permission == .accessibility)
            #expect(services.automationStub.lastProcessTargetedClick == nil)
        }
    }

    @Test
    @MainActor
    func `remote accessibility-only host allows element right click`() async throws {
        let socketPath = "/tmp/wink-bridge-right-click-\(UUID().uuidString).sock"
        let services = StubServices()
        let server = WinkBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let host = WinkBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = try await self.legacyUnprojectedClient(socketPath: socketPath)

        let remote = RemoteUIAutomationService(
            client: client,
            supportsTargetedClicks: true,
            targetedClickRequiresEventSynthesizingPermission: true)

        try await remote.click(
            target: .elementId("B1"),
            clickType: .right,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001)

        #expect(services.automationStub.lastProcessTargetedClick?.type == .right)
    }

    @Test
    @MainActor
    func `remote element right click preserves synthetic permission denial in canonical failure`() async throws {
        let socketPath = "/tmp/wink-bridge-right-click-\(UUID().uuidString).sock"
        let services = StubServices()
        services.automationStub.targetedClickError = WinkError.permissionDeniedEventSynthesizing
        let server = WinkBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let host = WinkBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = try await self.legacyUnprojectedClient(socketPath: socketPath)

        let remote = RemoteUIAutomationService(
            client: client,
            supportsTargetedClicks: true,
            targetedClickRequiresEventSynthesizingPermission: true)

        do {
            try await remote.click(
                target: .query("Save"),
                clickType: .right,
                snapshotId: "snapshot",
                targetProcessIdentifier: 9001)
            Issue.record("Expected Event Synthesizing permission error")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.message == WinkError.permissionDeniedEventSynthesizing.localizedDescription)
            #expect(failure.causeDescription == "permissionDeniedEventSynthesizing")
        }
    }

    @Test
    @MainActor
    func `remote coordinate click is not preflight-rejected on an accessibility-only host`() async {
        // Current hosts deliver coordinate targeted clicks through accessibility, so the client
        // must not reject them for missing Event Synthesizing even when the legacy availability
        // flag is set. The request must reach transport (and here fail against a missing socket)
        // rather than throw `permissionDeniedEventSynthesizing` up front.
        let remote = RemoteUIAutomationService(
            client: WinkBridgeClient(
                socketPath: "/tmp/wink-missing-\(UUID().uuidString).sock",
                requestTimeoutSec: 0.1),
            supportsTargetedClicks: true,
            targetedClickRequiresEventSynthesizingPermission: true)

        do {
            try await remote.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: 9001)
            Issue.record("Expected a transport error against the missing socket")
        } catch WinkError.permissionDeniedEventSynthesizing {
            Issue.record("Coordinate click must not be preflight-rejected for Event Synthesizing")
        } catch {
            // Expected: the request reached transport and failed to connect to the missing socket.
        }
    }

    @Test
    @MainActor
    func `remote exact window click rejects an older bridge before transport`() async {
        let remote = RemoteUIAutomationService(
            client: WinkBridgeClient(
                socketPath: "/tmp/wink-missing-\(UUID().uuidString).sock",
                requestTimeoutSec: 0.1),
            supportsTargetedClicks: true,
            supportsExactWindowTargetedClicks: false)

        do {
            try await remote.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                expectedWindowIdentity: WindowMutationIdentity(
                    windowID: 42,
                    ownerProcessIdentifier: 9001,
                    ownerProcessStartIdentity: 1),
                expectedWindowBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
            Issue.record("Expected exact-window capability error")
        } catch WinkError.serviceUnavailable {
            // Expected before the missing socket is contacted.
        } catch {
            Issue.record("Unexpected transport or capability error: \(error)")
        }
    }

    @Test
    func `pointer operations declare their actual permissions`() {
        #expect(WinkBridgeOperation.targetedHotkey.requiredPermissions == [.postEvent])
        #expect(WinkBridgeOperation.targetedClick.requiredPermissions == [.accessibility])
        #expect(WinkBridgeOperation.exactWindowTargetedClick.requiredPermissions == [.accessibility])
        #expect(WinkBridgeOperation.click.requiredPermissions == [.postEvent])
        #expect(WinkBridgeOperation.moveMouse.requiredPermissions == [.postEvent])
        #expect(WinkBridgeOperation.drag.requiredPermissions == [.postEvent])
        #expect(WinkBridgeOperation.swipe.requiredPermissions == [.postEvent])
        #expect(WinkBridgeOperation.scroll.requiredPermissions == [.postEvent])
        #expect(WinkBridgeOperation.targetedScroll.requiredPermissions == [.accessibility])
        #expect(!WinkBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .elementId("B1"),
            clickType: .right))
        #expect(!WinkBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .query("Save"),
            clickType: .right))
        #expect(WinkBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .right))
        #expect(WinkBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .elementId("B1"),
            clickType: .double))
        #expect(WinkBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .elementId("B1"),
            clickType: .middle))
        #expect(WinkBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .query("Save"),
            clickType: .triple))
    }

    @Test
    @MainActor
    func `scroll bridge permission follows explicit delivery mode`() async throws {
        let background = WinkBridgeRequest.targetedScroll(WinkBridgeScrollRequest(request: ScrollRequest(
            direction: .down,
            amount: 1,
            target: "S1")))
        let foreground = WinkBridgeRequest.scroll(WinkBridgeScrollRequest(request: ScrollRequest(
            direction: .down,
            amount: 1,
            foreground: true)))

        let postEventOnly = WinkBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { true },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: false, postEvent: true)
            })
        let backgroundResponse = try await self.decode(postEventOnly.decodeAndHandle(
            JSONEncoder.winkBridgeEncoder().encode(background),
            peer: nil))
        guard case let .error(backgroundError) = backgroundResponse else {
            Issue.record("Expected background scroll permission error")
            return
        }
        #expect(backgroundError.code == .versionMismatch)
        #expect(backgroundError.permission == nil)

        let accessibilityOnly = WinkBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: false)
            })
        let foregroundResponse = try await self.decode(accessibilityOnly.decodeAndHandle(
            JSONEncoder.winkBridgeEncoder().encode(foreground),
            peer: nil))
        guard case let .error(foregroundError) = foregroundResponse else {
            Issue.record("Expected foreground scroll permission error")
            return
        }
        #expect(foregroundError.permission == .postEvent)
    }

    @Test
    @MainActor
    func `remote background scroll rejects stale bridge capability before transport`() async {
        let remote = RemoteUIAutomationService(
            client: WinkBridgeClient(
                socketPath: "/tmp/wink-missing-\(UUID().uuidString).sock",
                requestTimeoutSec: 0.1),
            supportsTargetedScroll: false)

        do {
            try await remote.scroll(ScrollRequest(direction: .down, amount: 1, target: "S1"))
            Issue.record("Expected targeted-scroll capability error")
        } catch let error as WinkError {
            #expect(error.localizedDescription.contains("exact-window background scroll receipts"))
        } catch {
            Issue.record("Unexpected transport error: \(error)")
        }
    }

    @Test
    func `element action operations require accessibility permission`() {
        #expect(WinkBridgeOperation.setValue.requiredPermissions == [.accessibility])
        #expect(WinkBridgeOperation.performAction.requiredPermissions == [.accessibility])
    }

    @Test
    func `desktop observation operation requires screen recording permission`() {
        #expect(WinkBridgeOperation.desktopObservation.requiredPermissions == [.screenRecording])
    }

    @Test
    func `native application lifecycle operations do not require AppleScript permission`() {
        #expect(WinkBridgeOperation.activateApplication.requiredPermissions.isEmpty)
        #expect(WinkBridgeOperation.quitApplication.requiredPermissions.isEmpty)
        #expect(WinkBridgeOperation.hideApplication.requiredPermissions.isEmpty)
        #expect(WinkBridgeOperation.unhideApplication.requiredPermissions.isEmpty)
        #expect(WinkBridgeOperation.hideOtherApplications.requiredPermissions.isEmpty)
        #expect(WinkBridgeOperation.showAllApplications.requiredPermissions.isEmpty)
    }
}
