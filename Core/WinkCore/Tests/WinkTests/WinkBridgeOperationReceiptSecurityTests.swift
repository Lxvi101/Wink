import Darwin
import Foundation
import WinkAutomationKit
import WinkBridgeTestSupport
import WinkFoundation
import Testing
@testable import WinkBridge
@testable import WinkCore

@Suite(.serialized)
struct WinkBridgeOperationReceiptSecurityTests {
    @Test
    func `handled no-dispatch outcome ignores unused target drift and stays retry-safe`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let expectedIdentity = ApplicationProcessIdentity(
            processIdentifier: getpid(),
            processStartIdentity: generation)
        let services = await MainActor.run {
            let services = StubServices()
            services.automationStub.actionOutcome = .refused(reason: .targetUnavailable)
            services.automationStub.uiAutomationOutcomeTargetIdentity = try? DesktopTargetIdentity(
                processIdentity: .init(
                    processIdentifier: getpid(),
                    processStartIdentity: generation + 1))
            services.automationStub.allowsContradictoryOutcomeTargetIdentityForTesting = true
            return services
        }
        let server = await MainActor.run {
            WinkBridgeServer(
                services: services,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
                })
        }
        let host = WinkBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()

        do {
            let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
            _ = try await client.handshake(client: Self.clientIdentity)
            do {
                _ = try await client.clickWithOutcome(
                    target: .elementId("B1"),
                    clickType: .single,
                    snapshotId: "snapshot",
                    expectedProcessIdentity: expectedIdentity)
                Issue.record("Expected contradictory result attribution to be refused")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.retrySafety == .safe)
                #expect(failure.outcome.dispatchState == .none)
            }
            let receipt = try #require(await client.lastOperationReceipt())
            #expect(receipt.payload.targetAttributionFailure == nil)
            #expect(receipt.payload.target == nil)
            #expect(receipt.payload.outcome?.state == .refused)
            #expect(receipt.payload.outcome?.retrySafe == true)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `receipt archive rejects permissive directories and symlinks`() throws {
        let permissive = URL(fileURLWithPath: "/tmp/pbor-permissive-\(UUID().uuidString)", isDirectory: true)
        let symlinkURL = URL(fileURLWithPath: "/tmp/pbor-symlink-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: permissive)
            unlink(symlinkURL.path)
        }
        try FileManager.default.createDirectory(at: permissive, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: permissive.path)
        #expect(throws: WinkBridgeOperationReceiptError.self) {
            try WinkBridgePrivateReceiptArchive.prepareDirectory(permissive)
        }

        #expect(symlink("/tmp", symlinkURL.path) == 0)
        #expect(throws: WinkBridgeOperationReceiptError.self) {
            try WinkBridgePrivateReceiptArchive.prepareDirectory(symlinkURL)
        }
    }

    @Test
    func `handshake rejects a signed attestation that contradicts the advertised CDHash`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WinkBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let attestation = authority.attestation
        let clientInstanceID = UUID()
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let handshake = WinkBridgeHandshakeResponse(
            negotiatedVersion: WinkBridgeConstants.attestedOperationReceiptVersion,
            hostKind: .gui,
            build: "test",
            supportedOperations: [.permissionsStatus],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [.permissionsStatus],
            hostIdentity: .init(
                processIdentifier: attestation.host.processIdentifier,
                processStartIdentity: attestation.host.processStartIdentity,
                bundleIdentifier: "dev.wink.tests",
                bundleShortVersion: "1",
                bundleVersion: "1",
                codeSignatureHash: "contradictory-cdhash"),
            hostCapabilities: [
                WinkBridgeHostCapability.attestedOperationReceipts,
                WinkBridgeHostCapability.desktopActionOutcomeProjection,
            ],
            operationAttestation: attestation,
            operationSessionAttestation: session.attestation)
        let handshakeData = try JSONEncoder.winkBridgeEncoder().encode(
            WinkBridgeResponse.handshake(handshake))
        let peer = try ScriptedBridgePeer(scripts: [[.respondData(handshakeData)]])
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 1,
            operationClientInstanceID: clientInstanceID)

        do {
            _ = try await client.handshake(client: Self.clientIdentity)
            Issue.record("Expected contradictory host CDHash to be rejected")
        } catch let envelope as WinkBridgeErrorEnvelope {
            #expect(envelope.code == .unauthorizedClient)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `handshake requires outcome projection for protocol 1 29 receipts`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WinkBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let attestation = authority.attestation
        let clientInstanceID = UUID()
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let handshake = WinkBridgeHandshakeResponse(
            negotiatedVersion: WinkBridgeConstants.attestedOperationReceiptVersion,
            hostKind: .gui,
            build: "test",
            supportedOperations: [.permissionsStatus],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [.permissionsStatus],
            hostIdentity: .init(
                processIdentifier: attestation.host.processIdentifier,
                processStartIdentity: attestation.host.processStartIdentity,
                bundleIdentifier: "dev.wink.tests",
                bundleShortVersion: "1",
                bundleVersion: "1",
                codeSignatureHash: attestation.host.codeSignatureHash),
            hostCapabilities: [WinkBridgeHostCapability.attestedOperationReceipts],
            operationAttestation: attestation,
            operationSessionAttestation: session.attestation)
        let handshakeData = try JSONEncoder.winkBridgeEncoder().encode(
            WinkBridgeResponse.handshake(handshake))
        let peer = try ScriptedBridgePeer(scripts: [[.respondData(handshakeData)]])
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 1,
            operationClientInstanceID: clientInstanceID)

        do {
            _ = try await client.handshake(client: Self.clientIdentity)
            Issue.record("Expected missing outcome projection to be rejected")
        } catch let envelope as WinkBridgeErrorEnvelope {
            #expect(envelope.code == .unauthorizedClient)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `raw attested mutations require projected outcome carriage`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WinkBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let rawRequest = WinkBridgeRequest.requestPostEventPermission
        let rawPayload = session.request(
            authority: authority,
            sequence: 0,
            request: rawRequest)

        #expect(throws: WinkBridgeErrorEnvelope.self) {
            _ = try rawPayload.validatedRequest()
        }

        let projectedRequest = WinkBridgeRequest.projectedAction(.init(request: rawRequest))
        let projected = try await session.acceptedClaim(
            authority: authority,
            sequence: 1,
            request: projectedRequest)
        let projectedPayload = projected.request
        #expect(try projectedPayload.validatedRequest().operation == .requestPostEventPermission)

        let response = WinkBridgeResponse.ok
        let receiptPayload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: projected.claim,
            request: rawRequest,
            response: response)
        #expect(throws: WinkBridgeOperationReceiptError.self) {
            try WinkBridgeOperationReceiptSemantics.validateReceiptCarriage(
                receiptPayload,
                request: projectedRequest,
                response: .ok)
        }
        #expect(throws: WinkBridgeOperationReceiptError.self) {
            try WinkBridgeOperationReceiptSemantics.validateReceiptCarriage(
                receiptPayload,
                request: projectedRequest,
                response: .projectedAction(.init(response: .ok, outcome: nil)))
        }
        let receipt = try await authority.signAndArchive(receiptPayload, claim: projected.claim)
        let bundle = try Self.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: rawRequest,
            response: response)
        #expect(throws: WinkBridgeOperationReceiptError.receiptMismatch(
            "the exported request or response bytes"))
        {
            try bundle.validate()
        }
        authority.complete(projected.claim)
    }

    @Test
    @MainActor
    func `nested typed projection carriage is signed as a retry safe refusal without dispatch`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WinkBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let services = StubServices()
        let server = WinkBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
            })
        let typedRequests: [WinkBridgeRequest] = [
            .typeActions(.init(
                actions: [.text("x")],
                cadence: .fixed(milliseconds: 0),
                snapshotId: "snapshot")),
            .setValue(.init(target: "B1", value: .string("x"), snapshotId: "snapshot")),
            .performAction(.init(target: "B1", actionName: "AXPress", snapshotId: "snapshot")),
        ]

        for (offset, typedRequest) in typedRequests.enumerated() {
            let malformedRequest = WinkBridgeRequest.projectedAction(.init(
                request: .projectedAction(.init(request: typedRequest))))
            let plan = WinkBridgeOperationResultSemantics.semanticPlan(for: malformedRequest)
            #expect(plan.operation == typedRequest.operation)
            #expect(plan.contract.completion == .readOnly)
            #expect(plan.responseFamilies.isEmpty)
            #expect(plan.typedResponseRule == .none)

            let requestPayload = session.request(
                authority: authority,
                sequence: UInt64(offset),
                request: malformedRequest)
            let data = try await WinkBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
                try await server.handleAttestedOperation(requestPayload, peer: session.peer)
            }
            guard case let .attestedOperation(attested) = try JSONDecoder.winkBridgeDecoder().decode(
                WinkBridgeResponse.self,
                from: data),
                case let .projectedAction(projected) = attested.response,
                case let .error(envelope) = projected.response
            else {
                Issue.record("Expected a signed projected invalid-carriage refusal")
                continue
            }
            #expect(envelope.code == .invalidRequest)
            #expect(projected.outcome == envelope.actionOutcome)
            #expect(projected.outcome?.state == .refused)
            #expect(projected.outcome?.mutationDispatched == false)
            #expect(projected.outcome?.retrySafe == true)
            #expect(projected.outcome?.refusalReason == .invalidRequest)
            #expect(attested.receipt.payload.operation == typedRequest.operation)
            #expect(attested.receipt.payload.target == nil)

            let bundle = try OperationReceiptSessionFixture.bundle(
                authority: authority,
                sessionAttestation: session.attestation,
                receipt: attested.receipt,
                request: malformedRequest,
                response: attested.response)
            try bundle.validateIntegrity()
        }

        #expect(services.automationStub.lastTypeActions == nil)
        #expect(services.automationStub.lastSetValue == nil)
        #expect(services.automationStub.lastPerformAction == nil)

        let forgedRequest = WinkBridgeRequest.projectedAction(.init(
            request: .projectedAction(.init(request: typedRequests[0]))))
        let forgedClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: UInt64(typedRequests.count),
            request: forgedRequest)
        defer { authority.complete(forgedClaim.claim) }
        let forgedOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let forgedResponse = WinkBridgeResponse.projectedAction(.init(
            response: .typeResult(BridgeTestFixtures.typeResult(for: [.text("x")])),
            outcome: forgedOutcome.projection))
        let forgedPayload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: forgedClaim.claim,
            request: forgedRequest,
            response: forgedResponse,
            target: .global,
            outcome: forgedOutcome.projection)
        let forgedReceipt = try await authority.signAndArchive(forgedPayload, claim: forgedClaim.claim)
        let forgedBundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: forgedReceipt,
            request: forgedRequest,
            response: forgedResponse)
        #expect(throws: WinkBridgeOperationReceiptError.receiptMismatch("attested request carriage")) {
            try forgedBundle.validateIntegrity()
        }
    }

    @Test
    func `offline bundle validation rejects signed operation semantics that contradict its bytes`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WinkBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let request = WinkBridgeRequest.permissionsStatus
        let response = WinkBridgeResponse.permissionsStatus(.init(
            screenRecording: true,
            accessibility: true))
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let claimed = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: request)
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: claimed.claim,
            request: request,
            response: response,
            operation: .daemonStatus)
        let receipt = try await authority.signAndArchive(payload, claim: claimed.claim)
        let bundle = try Self.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: request,
            response: response)

        #expect(throws: WinkBridgeOperationReceiptError.receiptMismatch(
            "the exported verification bundle"))
        {
            try bundle.validate()
        }
        authority.complete(claimed.claim)
    }

    @Test
    func `offline bundle validation rejects a signed target that contradicts its request`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WinkBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let expectedIdentity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 1001)
        let contradictoryIdentity = ApplicationProcessIdentity(
            processIdentifier: 43,
            processStartIdentity: 2002)
        let request = WinkBridgeRequest.activateApplication(.init(
            identifier: "dev.wink.fixture",
            expectedIdentity: expectedIdentity))
        let projectedRequest = WinkBridgeRequest.projectedAction(.init(request: request))
        let outcome = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one)
        let response = WinkBridgeResponse.projectedAction(.init(
            response: .ok,
            outcome: outcome.projection))
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let claimed = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: projectedRequest)
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: claimed.claim,
            request: projectedRequest,
            response: response,
            target: .process(contradictoryIdentity),
            outcome: outcome.projection)
        try WinkBridgeOperationReceiptSemantics.validateReceiptCarriage(
            payload,
            request: projectedRequest,
            response: response)
        let receipt = try await authority.signAndArchive(payload, claim: claimed.claim)
        let bundle = try Self.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: projectedRequest,
            response: response)

        #expect(throws: WinkBridgeOperationReceiptError.receiptMismatch(
            "canonical target attribution"))
        {
            try bundle.validate()
        }
        authority.complete(claimed.claim)
    }

    @Test
    func `offline bundle validation reproduces a claimed attribution failure`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WinkBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let identity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 1001)
        let request = WinkBridgeRequest.activateApplication(.init(
            identifier: "dev.wink.fixture",
            expectedIdentity: identity))
        let failure = WinkBridgeTargetAttributionFailure(
            .contradictoryProcessIdentifier,
            stage: .preDispatch)
        let actionFailure = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .invalidRequest,
            message: "Forged target attribution failure")
        let projectedRequest = WinkBridgeRequest.projectedAction(.init(request: request))
        let response = WinkBridgeResponse.projectedAction(.init(
            response: .error(.init(
                code: .invalidRequest,
                actionFailure: actionFailure,
                context: "bridge_target_attribution:\(failure.code.rawValue)")),
            outcome: actionFailure.outcome.projection))
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let claimed = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: projectedRequest)
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: claimed.claim,
            request: projectedRequest,
            response: response,
            target: nil,
            targetAttributionFailure: failure,
            targetAttributionEvidence: request.operationTargetEvidence.map(
                WinkBridgeOperationTargetEvidence.init),
            outcome: actionFailure.outcome.projection)
        try WinkBridgeOperationReceiptSemantics.validateReceiptCarriage(
            payload,
            request: projectedRequest,
            response: response)
        let receipt = try await authority.signAndArchive(payload, claim: claimed.claim)
        let bundle = try Self.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: projectedRequest,
            response: response)

        #expect(throws: WinkBridgeOperationReceiptError.receiptMismatch(
            "claimed pre-dispatch target attribution failure"))
        {
            try bundle.validate()
        }
        authority.complete(claimed.claim)
    }

    @Test
    func `offline validation rejects unpinned success and malformed retry semantics`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WinkBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)

        let focusedBounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let focusedIdentity = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: focusedBounds)
        let focusRequest = WinkBridgeRequest.focusWindow(.init(
            target: .windowId(focusedIdentity.windowID),
            expectedIdentity: focusedIdentity))
        let projectedFocusRequest = WinkBridgeRequest.projectedAction(.init(request: focusRequest))
        let successOutcome = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .composite, mode: .foreground),
            unitCount: .one)
        let successResponse = WinkBridgeResponse.projectedAction(.init(
            response: .window(.init(
                windowID: focusedIdentity.windowID,
                title: "Fixture",
                bounds: focusedBounds,
                isKeyWindow: true,
                mutationIdentity: focusedIdentity)),
            outcome: successOutcome.projection))
        let successClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: projectedFocusRequest)
        let successPayload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: successClaim.claim,
            request: projectedFocusRequest,
            response: successResponse,
            outcome: successOutcome.projection)
        try WinkBridgeOperationReceiptSemantics.validateReceiptCarriage(
            successPayload,
            request: projectedFocusRequest,
            response: successResponse)
        let successReceipt = try await authority.signAndArchive(successPayload, claim: successClaim.claim)
        let successBundle = try Self.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: successReceipt,
            request: projectedFocusRequest,
            response: successResponse)
        #expect(throws: WinkBridgeOperationReceiptError.receiptMismatch(
            "canonical target attribution"))
        {
            try successBundle.validate()
        }

        let mutationRequest = WinkBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 42))
        let failure = WinkBridgeTargetAttributionFailure(
            .missingProcessGeneration,
            stage: .preDispatch)
        let malformedFailure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Missing retry-safe refusal semantics")
        let projectedMutationRequest = WinkBridgeRequest.projectedAction(.init(request: mutationRequest))
        let malformedResponse = WinkBridgeResponse.projectedAction(.init(
            response: .error(.init(
                code: .invalidRequest,
                actionFailure: malformedFailure,
                context: "bridge_target_attribution:\(failure.code.rawValue)")),
            outcome: malformedFailure.outcome.projection))
        let failureClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 1,
            request: projectedMutationRequest)
        let failurePayload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: failureClaim.claim,
            request: projectedMutationRequest,
            response: malformedResponse,
            target: nil,
            targetAttributionFailure: failure,
            targetAttributionEvidence: mutationRequest.operationTargetEvidence.map(
                WinkBridgeOperationTargetEvidence.init),
            outcome: malformedFailure.outcome.projection)
        try WinkBridgeOperationReceiptSemantics.validateReceiptCarriage(
            failurePayload,
            request: projectedMutationRequest,
            response: malformedResponse)
        let failureReceipt = try await authority.signAndArchive(failurePayload, claim: failureClaim.claim)
        let failureBundle = try Self.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: failureReceipt,
            request: projectedMutationRequest,
            response: malformedResponse)
        #expect(throws: WinkBridgeOperationReceiptError.receiptMismatch(
            "retry-safe target attribution refusal"))
        {
            try failureBundle.validate()
        }

        let safeFailure = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .invalidRequest,
            message: "Target attribution was refused")
        let nestedEnvelope = WinkBridgeErrorEnvelope(
            code: .invalidRequest,
            actionFailure: safeFailure,
            context: "bridge_target_attribution:\(failure.code.rawValue)")
        let contradictoryProjectedResponse = WinkBridgeResponse.projectedAction(.init(
            response: .error(nestedEnvelope),
            outcome: DesktopActionOutcome.confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .background)).projection))
        let contradictoryPayload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: failureClaim.claim,
            request: projectedMutationRequest,
            response: contradictoryProjectedResponse,
            target: nil,
            targetAttributionFailure: failure,
            targetAttributionEvidence: mutationRequest.operationTargetEvidence.map(
                WinkBridgeOperationTargetEvidence.init),
            outcome: WinkBridgeOperationReceiptSemantics.outcome(in: contradictoryProjectedResponse))
        #expect(throws: WinkBridgeOperationReceiptError.receiptMismatch("projected error outcome")) {
            try WinkBridgeOperationReceiptSemantics.validateTargetAttribution(
                contradictoryPayload,
                request: projectedMutationRequest,
                response: contradictoryProjectedResponse)
        }
        authority.complete(successClaim.claim)
        authority.complete(failureClaim.claim)
    }

    @Test
    func `request evidence preserves focused process and activation generations`() throws {
        let identity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 9_007_199_254_740_993)
        let focused = WinkBridgeRequest.getFocusedElement(.init(
            targetProcessIdentifier: identity.processIdentifier,
            expectedProcessIdentity: identity))
        let activate = WinkBridgeRequest.activateApplication(.init(
            identifier: "dev.wink.fixture",
            expectedIdentity: identity))
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let windowIdentity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: identity.processIdentifier,
            ownerProcessStartIdentity: identity.processStartIdentity,
            capturedBounds: bounds)
        let focus = WinkBridgeRequest.focusWindow(.init(
            target: .windowId(windowIdentity.windowID),
            expectedIdentity: windowIdentity))

        #expect(try WinkBridgeOperationTargetAttribution.resolveRequest(focused)?.processIdentity == identity)
        #expect(try WinkBridgeOperationTargetAttribution.resolveRequest(activate)?.processIdentity == identity)
        #expect(try WinkBridgeOperationTargetAttribution.resolveRequest(focus)?.exactWindow?.identity ==
            windowIdentity)
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try WinkBridgeOperationTargetAttribution.resolveRequest(.activateApplication(.init(
                identifier: "dev.wink.fixture")))
        }
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try WinkBridgeOperationTargetAttribution.resolveRequest(.quitApplication(.init(
                identifier: "dev.wink.fixture",
                force: false)))
        }
        let wireEvidence = WinkBridgeOperationTargetEvidence(.init(processIdentity: identity))
        let encodedEvidence = try WinkBridgeOperationReceiptCoding.canonicalData(wireEvidence)
        let encodedEvidenceString = try #require(String(data: encodedEvidence, encoding: .utf8))
        #expect(encodedEvidenceString.contains("\"9007199254740993\""))
        #expect(try JSONDecoder.winkBridgeDecoder().decode(
            WinkBridgeOperationTargetEvidence.self,
            from: encodedEvidence) == wireEvidence)
        #expect(throws: DesktopTargetIdentityError.missingProcessGeneration) {
            _ = try WinkBridgeOperationTargetAttribution.resolveRequest(.getFocusedElement(.init(
                targetProcessIdentifier: identity.processIdentifier)))
        }
        #expect(throws: DesktopTargetIdentityError.missingProcessGeneration) {
            _ = try WinkBridgeOperationTargetAttribution.resolveRequest(.focusWindow(.init(
                target: .windowId(windowIdentity.windowID))))
        }
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try WinkBridgeOperationTargetAttribution.resolveRequest(.focusWindow(.init(
                target: .application("Fixture"))))
        }
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try WinkBridgeOperationTargetAttribution.resolveReceipt(
                request: .focusWindow(.init(target: .application("Fixture"))),
                response: .ok)
        }
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try WinkBridgeOperationTargetAttribution.resolveReceipt(
                request: .click(.init(
                    target: .elementId("B1"),
                    clickType: .single,
                    snapshotId: nil)),
                response: .ok)
        }
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try WinkBridgeOperationTargetAttribution.resolveReceipt(
                request: .type(.init(
                    text: "x",
                    target: "B1",
                    clearExisting: false,
                    typingDelay: 0,
                    snapshotId: nil)),
                response: .ok)
        }
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try WinkBridgeOperationTargetAttribution.resolveReceipt(
                request: .targetedScroll(.init(request: .init(
                    direction: .down,
                    amount: 1,
                    target: "S1",
                    snapshotId: "snapshot"))),
                response: .ok)
        }
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try WinkBridgeOperationTargetAttribution.resolveReceipt(
                request: .setValue(.init(target: "S1", value: .string("x"), snapshotId: "snapshot")),
                response: .elementActionResult(.init(target: "S1", actionName: nil, anchorPoint: nil)))
        }
    }

    private static var clientIdentity: WinkBridgeClientIdentity {
        WinkBridgeClientIdentity(
            bundleIdentifier: "dev.wink.receipt-security-tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil)
    }

    private static func bundle(
        authority: WinkBridgeOperationReceiptAuthority,
        sessionAttestation: WinkBridgeOperationSessionAttestation,
        receipt: WinkBridgeOperationReceipt,
        request: WinkBridgeRequest,
        response: WinkBridgeResponse) throws -> WinkBridgeOperationReceiptBundle
    {
        try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: sessionAttestation,
            receipt: receipt,
            request: request,
            response: response)
    }
}
