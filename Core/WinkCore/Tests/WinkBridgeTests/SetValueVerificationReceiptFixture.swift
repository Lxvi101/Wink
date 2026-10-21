import CryptoKit
import Foundation
import WinkFoundation
@testable import WinkBridge

/// In-memory receipt signer with synthetic identities; never resolves a process or creates a host/archive.
enum SetValueVerificationReceiptFixture {
    static func bundle(
        requested: WinkBridgeRequest,
        response: WinkBridgeResponse) throws -> WinkBridgeOperationReceiptBundle
    {
        let key = Curve25519.Signing.PrivateKey()
        let host = WinkBridgeOperationProcessIdentity(
            processIdentifier: 71, processStartIdentity: 2001, codeSignatureHash: "synthetic-host")
        let client = WinkBridgeOperationProcessIdentity(
            processIdentifier: 72, processStartIdentity: 2002, codeSignatureHash: "synthetic-client")
        let listenerID = UUID()
        let sessionID = UUID()
        let clientID = UUID()
        let listenerPayload = WinkBridgeListenerAttestation.UnsignedPayload(
            schemaVersion: 1,
            listenerInstanceID: listenerID,
            publicKey: key.publicKey.rawRepresentation,
            host: host,
            createdAtUnixMilliseconds: 1000,
            receiptArchiveDirectory: "/synthetic/not-created")
        let listener = try WinkBridgeListenerAttestation(
            listenerInstanceID: listenerID,
            publicKey: listenerPayload.publicKey,
            host: host,
            createdAtUnixMilliseconds: listenerPayload.createdAtUnixMilliseconds,
            receiptArchiveDirectory: listenerPayload.receiptArchiveDirectory,
            signature: key.signature(for: WinkBridgeOperationReceiptCoding.canonicalData(listenerPayload)))
        let sessionPayload = WinkBridgeOperationSessionAttestation.UnsignedPayload(
            schemaVersion: 1,
            sessionID: sessionID,
            listenerInstanceID: listenerID,
            listenerPublicKeySHA256: WinkBridgeOperationReceiptCoding.sha256(listener.publicKey),
            clientInstanceID: clientID,
            client: client,
            maximumRequestCount: 8,
            remainingClaimCount: 8,
            predecessorSessionID: nil,
            createdAtUnixMilliseconds: 1001)
        let session = try WinkBridgeOperationSessionAttestation(
            sessionID: sessionID,
            listenerInstanceID: listenerID,
            listenerPublicKeySHA256: sessionPayload.listenerPublicKeySHA256,
            clientInstanceID: clientID,
            client: client,
            maximumRequestCount: sessionPayload.maximumRequestCount,
            remainingClaimCount: sessionPayload.remainingClaimCount,
            predecessorSessionID: nil,
            createdAtUnixMilliseconds: sessionPayload.createdAtUnixMilliseconds,
            signature: key.signature(for: WinkBridgeOperationReceiptCoding.canonicalData(sessionPayload)))
        let sequence = WinkBridgeOperationSessionSequence(0)
        let payload = try WinkBridgeOperationReceiptPayload(
            requestID: WinkBridgeOperationReceiptCoding.deterministicRequestID(
                sessionID: sessionID, sequence: sequence),
            sessionID: sessionID,
            sessionSequence: sequence,
            sessionAttestationSHA256: WinkBridgeOperationReceiptCoding.sha256(session),
            listenerInstanceID: listenerID,
            listenerPublicKeySHA256: sessionPayload.listenerPublicKeySHA256,
            host: host,
            clientInstanceID: clientID,
            client: client,
            operation: requested.operation,
            requestSHA256: WinkBridgeOperationReceiptCoding.sha256(requested),
            responseSHA256: WinkBridgeOperationReceiptCoding.sha256(response),
            target: .process(.init(processIdentifier: 42, processStartIdentity: 1001)),
            outcome: WinkBridgeOperationReceiptSemantics.outcome(in: response),
            remainingClaimCount: 7,
            startedAtUnixMilliseconds: 1002,
            completedAtUnixMilliseconds: 1003)
        let receipt = try WinkBridgeOperationReceipt(
            payload: payload,
            signature: key.signature(for: WinkBridgeOperationReceiptCoding.canonicalData(payload)))
        return try WinkBridgeOperationReceiptBundle(
            operationAttestation: listener,
            operationSessionAttestation: session,
            receipt: receipt,
            canonicalListenerAttestationPayload: WinkBridgeOperationReceiptCoding.canonicalData(listenerPayload),
            canonicalSessionAttestationPayload: WinkBridgeOperationReceiptCoding.canonicalData(sessionPayload),
            canonicalReceiptPayload: WinkBridgeOperationReceiptCoding.canonicalData(payload),
            canonicalRequest: WinkBridgeOperationReceiptCoding.canonicalData(requested),
            canonicalResponse: WinkBridgeOperationReceiptCoding.canonicalData(response))
    }
}
