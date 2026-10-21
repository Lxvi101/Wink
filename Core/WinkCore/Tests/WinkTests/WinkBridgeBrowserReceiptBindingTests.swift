import Foundation
import WinkAutomationKit
import WinkFoundation
import Testing
@testable import WinkBridge

@Suite(.serialized)
struct WinkBridgeBrowserReceiptBindingTests {
    @Test(arguments: BrowserResponseProgressFixture.cases)
    func `signed browser progress preserves its stronger evidence contract`(
        fixture: BrowserResponseProgressFixture) async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wink-browser-progress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WinkBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let bundle = try await session.signedBundle(
            authority: authority,
            sequence: 0,
            request: .projectedAction(.init(request: BrowserResponseProgressFixture.request)),
            response: fixture.response,
            target: fixture.outcome.state == .refused ? nil : .process(BrowserResponseProgressFixture.identity),
            outcome: fixture.outcome.projection)
        if fixture.acceptsSigned {
            try bundle.validate()
        } else {
            #expect(throws: WinkBridgeOperationReceiptError.self) {
                try bundle.validate()
            }
        }
    }

    @Test
    func `browser request read classification is shared across Bridge adapters`() {
        #expect(WinkBridgeBrowserExecuteRequest(
            toolName: "list_pages",
            arguments: [:]).isReadOnly)
        #expect(!WinkBridgeBrowserExecuteRequest(
            toolName: "click",
            arguments: [:]).isReadOnly)
    }

    @Test
    func `process bound DevTools receipt is canonical for native binding protocol`() {
        let receipt = WinkBridgeBrowserConnectionReceipt(
            channel: "stable",
            processIdentifier: 42,
            processStartIdentity: 10042,
            bundleIdentifier: "com.google.Chrome",
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")

        #expect(receipt.isCanonicalProcessBoundTarget)
        #expect(receipt.isCanonicalTarget)
        #expect(receipt.matchesConnectRequest(.init(channel: "stable")))
        #expect(!receipt.isCanonicalExternalTarget)
    }

    @Test
    func `process bound browser receipts require exact canonical channel bundle pairs`() {
        let invalidPairs: [(String?, String?)] = [
            (nil, "com.google.Chrome"),
            ("", "com.google.Chrome"),
            ("stable", nil),
            ("stable", ""),
            ("stable", "com.google.Chrome.helper"),
            ("stable", "COM.GOOGLE.CHROME"),
            ("stable", "com.google.Chrome.canary"),
            ("canary", "com.google.Chrome"),
            ("unknown", "com.google.Chrome"),
        ]

        for (channel, bundleIdentifier) in invalidPairs {
            let receipt = WinkBridgeBrowserConnectionReceipt(
                channel: channel,
                processIdentifier: 42,
                processStartIdentity: 10042,
                bundleIdentifier: bundleIdentifier,
                browserURL: "http://127.0.0.1:9222/",
                webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
                devToolsBrowserID: "browser-a",
                browserVersion: "Chrome/151.0",
                protocolVersion: "1.3")
            #expect(!receipt.isCanonicalProcessBoundTarget)
            #expect(!receipt.isCanonicalTarget)
        }
    }

    @Test
    func `external browser receipt permits nil or one supported canonical channel only`() {
        func receipt(channel: String?) -> WinkBridgeBrowserConnectionReceipt {
            WinkBridgeBrowserConnectionReceipt(
                channel: channel,
                browserURL: "http://127.0.0.1:9222/",
                webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
                devToolsBrowserID: "browser-a",
                browserVersion: "Chrome/151.0",
                protocolVersion: "1.3")
        }

        #expect(receipt(channel: nil).isCanonicalExternalTarget)
        #expect(receipt(channel: "stable").isCanonicalExternalTarget)
        #expect(!receipt(channel: "STABLE").isCanonicalExternalTarget)
        #expect(!receipt(channel: "unknown").isCanonicalExternalTarget)
        #expect(!receipt(channel: "").isCanonicalExternalTarget)
    }

    @Test
    func `binding a result aware mutation to status forbids reconnect and retarget`() {
        let requests = [
            WinkBridgeBrowserExecuteRequest(
                toolName: "click",
                arguments: ["uid": .string("7_1")],
                channel: "stable"),
            WinkBridgeBrowserExecuteRequest(
                calls: [
                    .init(toolName: "click", arguments: ["uid": .string("7_1")]),
                    .init(toolName: "type_text", arguments: ["text": .string("hello")]),
                ],
                channel: "stable"),
        ]

        for request in requests {
            #expect(request.connectionPolicy == nil)

            let bound = request.binding(to: Self.localReceipt)

            #expect(bound.expectedConnectionReceipt == Self.localReceipt)
            #expect(bound.connectionPolicy == .requireExistingLiveReceipt)
            #expect(bound.resolvedCalls == request.resolvedCalls)
            #expect(bound.channel == request.channel)
        }
    }

    @Test
    @MainActor
    func `browser target inspection preserves an existing typed refusal`() async throws {
        let services = StubServices()
        let expected = DesktopActionFailure.preDispatchRefusal(
            reason: .permissionDenied,
            message: "Browser status inspection requires permission.",
            hint: "Grant permission before retrying.",
            causeDescription: "typed fixture")
        services.browserStatusError = expected

        do {
            _ = try await Self.handleBrowserExecute(services: services)
            Issue.record("Expected the typed browser status refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure == expected)
        }
    }

    @Test
    @MainActor
    func `browser target inspection maps unsupported provider to canonical refusal`() async throws {
        let services = StubServices()
        services.browserStatusError = WinkBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "Browser provider cannot report an exact connection.",
            details: "unsupported fixture")

        do {
            _ = try await Self.handleBrowserExecute(services: services)
            Issue.record("Expected the unsupported browser provider refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .operationUnsupported)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.causeDescription == "unsupported fixture")
        }
    }

    @Test
    @MainActor
    func `browser target inspection synthesizes unavailable only for untyped failure`() async throws {
        let services = StubServices()
        services.browserStatusError = BrowserStatusInspectionError()

        do {
            _ = try await Self.handleBrowserExecute(services: services)
            Issue.record("Expected the untyped browser status failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.causeDescription == "untyped browser status fixture")
        }
    }

    @Test
    func `local browser dispatch requires exact binding while no dispatch may omit it`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wink-local-browser-receipt-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WinkBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let localReceipt = WinkBridgeBrowserConnectionReceipt(
            channel: "stable",
            processIdentifier: 42,
            processStartIdentity: 10042,
            bundleIdentifier: "com.google.Chrome",
            browserVersion: "Chrome/151.0")
        let changedLocalReceipt = WinkBridgeBrowserConnectionReceipt(
            channel: "stable",
            processIdentifier: 42,
            processStartIdentity: 10043,
            bundleIdentifier: "com.google.Chrome",
            browserVersion: "Chrome/151.0")
        let calls = [
            WinkBridgeBrowserToolCall(toolName: "click", arguments: [:]),
            WinkBridgeBrowserToolCall(toolName: "type", arguments: [:]),
        ]
        let boundRequest = WinkBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            calls: calls,
            channel: "stable",
            expectedConnectionReceipt: localReceipt))))
        let unboundRequest = WinkBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            calls: calls,
            channel: "stable"))))
        let success = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))

        func makeBundle(
            sequence: UInt64,
            request: WinkBridgeRequest,
            browserResponse: WinkBridgeBrowserToolResponse,
            outcome: DesktopActionOutcome,
            target: WinkBridgeOperationTargetReceipt?) async throws
            -> WinkBridgeOperationReceiptBundle
        {
            let response = WinkBridgeResponse.projectedAction(.init(
                response: .browserToolResponse(browserResponse),
                outcome: outcome.projection))
            let accepted = try await session.acceptedClaim(
                authority: authority,
                sequence: sequence,
                request: request)
            let payload = try OperationReceiptSessionFixture.receiptPayload(
                authority: authority,
                claim: accepted.claim,
                request: request,
                response: response,
                target: target,
                outcome: outcome.projection)
            let receipt = try await authority.signAndArchive(payload, claim: accepted.claim)
            let bundle = try OperationReceiptSessionFixture.bundle(
                authority: authority,
                sessionAttestation: session.attestation,
                receipt: receipt,
                request: request,
                response: response)
            authority.complete(accepted.claim)
            return bundle
        }

        let changedIdentity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 10043)
        let substituted = try await makeBundle(
            sequence: 0,
            request: boundRequest,
            browserResponse: .init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: changedLocalReceipt,
                completedCallCount: 2,
                dispatchedCallCount: 2),
            outcome: success,
            target: .process(changedIdentity))
        #expect(throws: WinkBridgeOperationReceiptError.self) {
            try substituted.validate()
        }

        let localIdentity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 10042)
        let missingBinding = try await makeBundle(
            sequence: 1,
            request: unboundRequest,
            browserResponse: .init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: localReceipt,
                completedCallCount: 2,
                dispatchedCallCount: 2),
            outcome: success,
            target: .process(localIdentity))
        #expect(throws: WinkBridgeOperationReceiptError.self) {
            try missingBinding.validate()
        }

        let refusal = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "Browser target disappeared before dispatch")
        let noDispatch = try await makeBundle(
            sequence: 2,
            request: unboundRequest,
            browserResponse: .init(
                content: [],
                isError: true,
                meta: nil,
                connectionReceipt: localReceipt,
                completedCallCount: 0,
                dispatchedCallCount: 0,
                actionFailure: refusal),
            outcome: refusal.outcome,
            target: nil)
        try noDispatch.validate()
        #expect(noDispatch.receipt.payload.outcome?.retrySafe == true)
    }

    @Test
    func `browser receipt progress is bounded by the requested batch`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wink-browser-batch-bounds-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WinkBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)

        let threeCallRequest = WinkBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            calls: [
                .init(toolName: "click", arguments: [:]),
                .init(toolName: "type", arguments: [:]),
                .init(toolName: "hover", arguments: [:]),
            ],
            channel: "stable",
            expectedConnectionReceipt: Self.localReceipt))))
        let localIdentity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 10042)

        func makeBundle(
            sequence: UInt64,
            completedCallCount: Int,
            dispatchedCallCount: Int,
            outcome: DesktopActionOutcome,
            request requestedRequest: WinkBridgeRequest? = nil) async throws -> WinkBridgeOperationReceiptBundle
        {
            let request = requestedRequest ?? threeCallRequest
            let response = WinkBridgeResponse.projectedAction(.init(
                response: .browserToolResponse(.init(
                    content: [],
                    isError: false,
                    meta: nil,
                    connectionReceipt: Self.localReceipt,
                    completedCallCount: completedCallCount,
                    dispatchedCallCount: dispatchedCallCount)),
                outcome: outcome.projection))
            let accepted = try await session.acceptedClaim(
                authority: authority,
                sequence: sequence,
                request: request)
            let payload = try OperationReceiptSessionFixture.receiptPayload(
                authority: authority,
                claim: accepted.claim,
                request: request,
                response: response,
                target: .process(localIdentity),
                outcome: outcome.projection)
            let receipt = try await authority.signAndArchive(payload, claim: accepted.claim)
            let bundle = try OperationReceiptSessionFixture.bundle(
                authority: authority,
                sessionAttestation: session.attestation,
                receipt: receipt,
                request: request,
                response: response)
            authority.complete(accepted.claim)
            return bundle
        }

        let oneCallSuccess = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let incompleteSuccess = try await makeBundle(
            sequence: 0,
            completedCallCount: 1,
            dispatchedCallCount: 1,
            outcome: oneCallSuccess)
        #expect(throws: WinkBridgeOperationReceiptError.self) {
            try incompleteSuccess.validate()
        }

        let fourCallCount = DesktopActionOutcome.DispatchUnitCount(4)
        let inflatedOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: fourCallCount)
        let inflatedSuccess = try await makeBundle(
            sequence: 1,
            completedCallCount: 4,
            dispatchedCallCount: 4,
            outcome: inflatedOutcome)
        #expect(throws: WinkBridgeOperationReceiptError.self) {
            try inflatedSuccess.validate()
        }

        let negativeProgress = try await makeBundle(
            sequence: 2,
            completedCallCount: -1,
            dispatchedCallCount: 1,
            outcome: oneCallSuccess)
        #expect(throws: WinkBridgeOperationReceiptError.self) {
            try negativeProgress.validate()
        }

        let mixedRequest = WinkBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            calls: [
                .init(toolName: "take_snapshot", arguments: [:]),
                .init(toolName: "click", arguments: [:]),
                .init(toolName: "list_console_messages", arguments: [:]),
            ],
            channel: "stable",
            expectedConnectionReceipt: Self.localReceipt))))
        let mixedSuccess = try await makeBundle(
            sequence: 3,
            completedCallCount: 1,
            dispatchedCallCount: 1,
            outcome: oneCallSuccess,
            request: mixedRequest)
        try mixedSuccess.validate()
    }

    @MainActor
    private static func handleBrowserExecute(services: StubServices) async throws -> WinkBridgeHandledResponse {
        let server = WinkBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in Self.permissions })
        let payload = WinkBridgeBrowserExecuteRequest(
            toolName: "click",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: Self.localReceipt)
        let request = WinkBridgeRequest.browserExecute(payload.binding(to: Self.localReceipt))
        return try await WinkBridgeRequestContext.$negotiatedSessionCapabilities.withValue(.current) {
            try await WinkBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                try await server.handleAuthorized(request, peer: nil, permissions: Self.permissions)
            }
        }
    }

    private static let localReceipt = WinkBridgeBrowserConnectionReceipt(
        channel: "stable",
        processIdentifier: 42,
        processStartIdentity: 10042,
        bundleIdentifier: "com.google.Chrome",
        browserURL: "http://127.0.0.1:9222/",
        webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
        devToolsBrowserID: "browser-a",
        browserVersion: "Chrome/151.0",
        protocolVersion: "1.3")

    private static let permissions = PermissionsStatus(
        screenRecording: true,
        accessibility: true,
        postEvent: true)
}

private struct BrowserStatusInspectionError: LocalizedError {
    var errorDescription: String? {
        "untyped browser status fixture"
    }
}
