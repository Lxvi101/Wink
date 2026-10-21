import Foundation
import Testing
@testable import WinkBridge

@Suite("Bridge certification producer attestation contract")
struct CertificationProducerAttestationContractTests {
    @Test
    func `Protocol allowlists and semantic plan keep certification read only`() {
        let previous = WinkBridgeProtocolVersion(major: 1, minor: 31)
        let current = WinkBridgeConstants.certificationProducerAttestationVersion
        #expect(WinkBridgeConstants.protocolVersion >= current)
        #expect(!WinkBridgeOperation.compatible(
            [.certificationProducerAttestation],
            with: previous).contains(.certificationProducerAttestation))
        #expect(WinkBridgeOperation.compatible(
            [.certificationProducerAttestation],
            with: current).contains(.certificationProducerAttestation))
        #expect(WinkBridgeOperation.remoteDefaultAllowlist.contains(.certificationProducerAttestation))
        #expect(WinkBridgeOperation.embeddedDefaultAllowlist.contains(.certificationProducerAttestation))
        #expect(WinkBridgeOperation.certificationProducerAttestation.requiredPermissions.isEmpty)

        let request = WinkBridgeRequest.certificationProducerAttestation(Self.request())
        let plan = WinkBridgeOperationResultSemantics.semanticPlan(for: request)
        #expect(request.minimumNegotiatedProtocolVersion == current)
        #expect(!request.mayMutateDesktop)
        #expect(!request.bypassesOuterDesktopMutationLane)
        #expect(plan.contract.completion == .readOnly)
        #expect(plan.contract.targetPolicy == .notApplicable)
        #expect(plan.responseFamilies == [.certificationProducerAttestation])
        #expect(plan.operationPolicy.typedResponse == .certificationProducerAttestation)
    }

    @Test
    @MainActor
    func `Server refuses certification without a signed receipt authority`() async {
        let server = WinkBridgeServer(
            services: WinkEmbeddedBridgeServices(),
            allowlistedTeams: ["FWJYW4S8P8"],
            allowlistedBundles: ["boo.wink.wink"])
        await #expect(throws: WinkBridgeErrorEnvelope.self) {
            _ = try await server.handleCertificationProducerAttestation(Self.request())
        }
    }

    @Test
    func `Request wire contains only transport authority and producer expectation`() throws {
        let data = try JSONEncoder.winkBridgeEncoder().encode(Self.request())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "schemaVersion", "kind", "executionNonce", "monitorInstanceID", "producerSocketPath",
            "expectedProducer", "timeoutMilliseconds", "maximumResponseBytes",
        ])
        let expected = try #require(object["expectedProducer"] as? [String: Any])
        #expect(Set(expected.keys) == [
            "processIdentifier", "processStartIdentity", "codeSignatureHash",
        ])
        #expect(expected["processStartIdentity"] as? String == "99")
        for forbidden in [
            "digest", "file", "message", "executable", "argv", "environment",
            "expectedResult", "predicate", "payload", "response",
        ] {
            #expect(object[forbidden] == nil)
        }
    }

    @Test
    func `Closed request rejects detached authority and unknown nested identity claims`() throws {
        let encoder = JSONEncoder.winkBridgeEncoder()
        let decoder = JSONDecoder.winkBridgeDecoder()
        let data = try encoder.encode(Self.request())
        let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        for forbidden in [
            "digest", "file", "message", "executable", "argv", "environment",
            "expectedResult", "predicate", "unknown",
        ] {
            var object = original
            object[forbidden] = forbidden == "argv" ? ["--unsafe"] : "forbidden"
            let injected = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            #expect(throws: DecodingError.self) {
                _ = try decoder.decode(
                    WinkBridgeCertificationProducerAttestationRequest.self,
                    from: injected)
            }
        }

        var nested = original
        var expected = try #require(nested["expectedProducer"] as? [String: Any])
        expected["signingIdentifier"] = "caller-selected"
        nested["expectedProducer"] = expected
        let nestedData = try JSONSerialization.data(withJSONObject: nested, options: [.sortedKeys])
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(
                WinkBridgeCertificationProducerAttestationRequest.self,
                from: nestedData)
        }
    }

    @Test
    func `Request transport bounds and canonical socket path fail closed`() {
        #expect(throws: WinkBridgeErrorEnvelope.self) {
            try Self.request(timeoutMilliseconds: 99).validate()
        }
        #expect(throws: WinkBridgeErrorEnvelope.self) {
            try Self.request(maximumResponseBytes: 1024 * 1024 + 1).validate()
        }
        #expect(throws: WinkBridgeErrorEnvelope.self) {
            try Self.request(producerSocketPath: "relative.sock").validate()
        }
        #expect(throws: WinkBridgeErrorEnvelope.self) {
            try Self.request(producerSocketPath: "/private/tmp/../substituted.sock").validate()
        }
    }

    @Test
    func `Wire envelope rejects kind and typed payload disagreement`() throws {
        let request = Self.request(kind: .monitorSeal)
        let listener = Self.listenerAttestation()
        let challenge = WinkBridgeCertificationProducerChallenge(
            kind: .monitorSeal,
            executionNonce: request.executionNonce,
            monitorInstanceID: request.monitorInstanceID,
            challenge: String(repeating: "c", count: 64),
            listenerInstanceID: listener.listenerInstanceID,
            listenerPublicKeySHA256: String(repeating: "d", count: 64))
        let response = WinkBridgeCertificationProducerWireResponse(
            kind: .monitorSeal,
            executionNonce: request.executionNonce,
            monitorInstanceID: request.monitorInstanceID,
            challenge: challenge.challenge,
            listenerInstanceID: listener.listenerInstanceID,
            listenerPublicKeySHA256: challenge.listenerPublicKeySHA256,
            payload: .crashInventoryPair(Self.crashPayload()))

        #expect(throws: WinkBridgeErrorEnvelope.self) {
            try WinkBridgeCertificationProducerTransport.validateWireEnvelope(
                response,
                request: request,
                challenge: challenge,
                listenerAttestation: listener)
        }

        let multipleCases = Data(#"{"crashInventoryPair":{},"monitorSeal":{}}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.winkBridgeDecoder().decode(
                WinkBridgeCertificationProducerPayload.self,
                from: multipleCases)
        }
    }

    @Test
    func `Crash inventory accepts only its exact derived delta`() throws {
        let payload = Self.crashPayload()
        try payload.validate(context: Self.validationContext())

        #expect(throws: WinkBridgeOperationReceiptError.self) {
            try payload.validate(context: Self.validationContext(
                executionNonce: String(repeating: "e", count: 64)))
        }

        let invalid = WinkBridgeCertificationCrashInventoryPairPayload(
            captureID: payload.captureID,
            source: payload.source,
            before: payload.before,
            after: payload.after,
            result: .init(passed: true, added: [], changed: [], removed: []))
        #expect(throws: WinkBridgeOperationReceiptError.self) {
            try invalid.validate(context: Self.validationContext())
        }
    }

    @Test
    func `Crash inventory decoder rejects detached paths and entry bounds fail closed`() throws {
        let encoder = JSONEncoder.winkBridgeEncoder()
        let decoder = JSONDecoder.winkBridgeDecoder()
        let encoded = try encoder.encode(Self.crashPayload())
        var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root["detachedInventoryDigest"] = String(repeating: "e", count: 64)
        let outerExtra = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(
                WinkBridgeCertificationCrashInventoryPairPayload.self,
                from: outerExtra)
        }

        root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var before = try #require(root["before"] as? [String: Any])
        before["inventoryPath"] = "/private/tmp/caller-selected.json"
        root["before"] = before
        let nestedExtra = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(
                WinkBridgeCertificationCrashInventoryPairPayload.self,
                from: nestedExtra)
        }

        let oversized = Self.crashPayload(entrySize: 64 * 1024 * 1024 + 1, includeAddedEntry: false)
        #expect(throws: WinkBridgeOperationReceiptError.self) {
            try oversized.validate(context: Self.validationContext())
        }
    }

    private static let executionNonce = String(repeating: "a", count: 64)
    private static let monitorInstanceID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private static let sourceCommit = String(repeating: "b", count: 40)
    private static let executableSHA256 = String(repeating: "c", count: 64)
    private static let codeSignatureHash = String(repeating: "d", count: 40)

    private static func request(
        kind: WinkBridgeCertificationProducerAttestationKind = .crashInventoryPair,
        executionNonce: String = Self.executionNonce,
        producerSocketPath: String = "/private/tmp/certification-producer.sock",
        timeoutMilliseconds: Int = 1000,
        maximumResponseBytes: Int = 1024 * 1024) -> WinkBridgeCertificationProducerAttestationRequest
    {
        .init(
            kind: kind,
            executionNonce: executionNonce,
            monitorInstanceID: self.monitorInstanceID,
            producerSocketPath: producerSocketPath,
            expectedProducer: .init(
                processIdentifier: 42,
                processStartIdentity: 99,
                codeSignatureHash: self.codeSignatureHash),
            timeoutMilliseconds: timeoutMilliseconds,
            maximumResponseBytes: maximumResponseBytes)
    }

    private static func crashPayload(
        entrySize: Int64 = 1024,
        includeAddedEntry: Bool = true) -> WinkBridgeCertificationCrashInventoryPairPayload
    {
        let first = WinkBridgeCertificationCrashInventoryPairPayload.Entry(
            name: "Wink-a.ips",
            size: entrySize,
            modifiedAtUnixMilliseconds: 900,
            sha256: String(repeating: "1", count: 64))
        let second = WinkBridgeCertificationCrashInventoryPairPayload.Entry(
            name: "Wink-b.ips",
            size: 2048,
            modifiedAtUnixMilliseconds: 2500,
            sha256: String(repeating: "2", count: 64))
        let added = includeAddedEntry ? [second] : []
        return .init(
            captureID: self.executionNonce,
            source: .init(
                sourceCommit: self.sourceCommit,
                executableSHA256: self.executableSHA256,
                catalogVersion: 2,
                monitorContractVersion: 1,
                catalogSHA256: String(repeating: "3", count: 64),
                scanDomain: .currentUserDiagnosticReports,
                crashReportPrefixes: ["Wink"]),
            before: .init(
                role: .matrixBefore,
                hostUUID: "00000000-0000-4000-8000-000000000002",
                hostname: "test-host",
                entries: [first],
                scanCount: 2,
                quietPeriodMilliseconds: 1000,
                captureStartedAtUnixMilliseconds: 1000,
                captureCompletedAtUnixMilliseconds: 2000),
            after: .init(
                role: .matrixAfter,
                hostUUID: "00000000-0000-4000-8000-000000000002",
                hostname: "test-host",
                entries: [first] + added,
                scanCount: 2,
                quietPeriodMilliseconds: 1000,
                captureStartedAtUnixMilliseconds: 2000,
                captureCompletedAtUnixMilliseconds: 3000),
            result: .init(
                passed: added.isEmpty,
                added: added,
                changed: [],
                removed: []))
    }

    private static func validationContext(
        executionNonce: String = Self.executionNonce) -> WinkBridgeCertificationPayloadValidationContext
    {
        .init(
            request: self.request(executionNonce: executionNonce),
            producer: .init(
                processIdentifier: 42,
                processIdentifierVersion: 1,
                processStartIdentity: 99,
                codeSignatureHash: self.codeSignatureHash,
                signingIdentifier: "boo.wink.wink-certification-controller",
                teamIdentifier: "FWJYW4S8P8",
                sourceCommit: self.sourceCommit,
                executableSHA256: self.executableSHA256),
            listenerAttestation: self.listenerAttestation())
    }

    private static func listenerAttestation() -> WinkBridgeListenerAttestation {
        .init(
            listenerInstanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            publicKey: Data(repeating: 0, count: 32),
            host: .init(
                processIdentifier: 7,
                processStartIdentity: 8,
                codeSignatureHash: String(repeating: "f", count: 40)),
            createdAtUnixMilliseconds: 1000,
            receiptArchiveDirectory: "/private/tmp/receipts",
            signature: Data())
    }
}
