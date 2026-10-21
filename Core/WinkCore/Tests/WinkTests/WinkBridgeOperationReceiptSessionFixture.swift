import Darwin
import Foundation
import WinkAutomationKit
import WinkFoundation
@testable import WinkBridge

enum OperationReceiptSessionFixtureError: Error {
    case missingProcessIdentity
    case expectedAcceptedClaim
    case expectedRolloverRefusal
}

struct OperationReceiptSessionFixture: Sendable {
    let clientInstanceID: UUID
    let peer: WinkBridgePeer
    let attestation: WinkBridgeOperationSessionAttestation

    static func make(
        authority: WinkBridgeOperationReceiptAuthority,
        clientInstanceID: UUID = UUID(),
        peer: WinkBridgePeer? = nil,
        negotiatedCapabilities: WinkBridgeNegotiatedSessionCapabilities = .current,
        replacing predecessorSessionID: UUID? = nil) async throws -> Self
    {
        let resolvedPeer = try peer ?? self.currentPeer()
        let attestation = try await authority.createSession(
            clientInstanceID: clientInstanceID,
            peer: resolvedPeer,
            negotiatedCapabilities: negotiatedCapabilities,
            replacing: predecessorSessionID)
        try attestation.validateSignature(listenerAttestation: authority.attestation)
        return Self(
            clientInstanceID: clientInstanceID,
            peer: resolvedPeer,
            attestation: attestation)
    }

    static func currentPeer(
        auditTokenProcessIdentifierVersion: Int32? = 1,
        processStartIdentity: UInt64? = nil,
        codeSignatureHash: String? = nil) throws -> WinkBridgePeer
    {
        guard let resolvedStartIdentity = processStartIdentity ??
            SystemIdentityResolver.processStartIdentity(getpid()),
            let resolvedCodeSignatureHash = codeSignatureHash ??
            WinkBridgeCodeSignatureIdentity.codeSignatureHash(processIdentifier: getpid())
        else {
            throw OperationReceiptSessionFixtureError.missingProcessIdentity
        }
        guard auditTokenProcessIdentifierVersion != nil else {
            return WinkBridgePeer(
                processIdentifier: getpid(),
                auditTokenProcessIdentifierVersion: nil,
                processStartIdentity: resolvedStartIdentity,
                codeSignatureHash: resolvedCodeSignatureHash,
                userIdentifier: geteuid(),
                bundleIdentifier: nil,
                teamIdentifier: nil)
        }
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let auditIdentity = try WinkBridgeSocketIO.peerAuditIdentity(fd: descriptors[0])
        let liveIdentity = WinkBridgeLivePeerIdentity(
            auditIdentity: auditIdentity,
            processStartIdentity: resolvedStartIdentity,
            codeSignatureHash: resolvedCodeSignatureHash)
        return WinkBridgePeer(
            liveIdentity: liveIdentity,
            bundleIdentifier: nil,
            teamIdentifier: nil)
    }

    func request(
        authority: WinkBridgeOperationReceiptAuthority,
        sequence: UInt64,
        request: WinkBridgeRequest) -> WinkBridgeAttestedOperationRequest
    {
        let sessionSequence = WinkBridgeOperationSessionSequence(sequence)
        return WinkBridgeAttestedOperationRequest(
            requestID: WinkBridgeOperationReceiptCoding.deterministicRequestID(
                sessionID: self.attestation.sessionID,
                sequence: sessionSequence),
            sessionID: self.attestation.sessionID,
            sessionSequence: sessionSequence,
            expectedListenerInstanceID: authority.attestation.listenerInstanceID,
            clientInstanceID: self.clientInstanceID,
            client: self.attestation.client,
            request: request)
    }

    func acceptedClaim(
        authority: WinkBridgeOperationReceiptAuthority,
        sequence: UInt64,
        request: WinkBridgeRequest) async throws
        -> (request: WinkBridgeAttestedOperationRequest, claim: WinkBridgeOperationSessionClaim)
    {
        let payload = self.request(authority: authority, sequence: sequence, request: request)
        guard case let .accepted(claim) = try await authority.claim(payload, peer: self.peer) else {
            throw OperationReceiptSessionFixtureError.expectedAcceptedClaim
        }
        return (payload, claim)
    }

    func rolloverRefusal(
        authority: WinkBridgeOperationReceiptAuthority,
        sequence: UInt64,
        request: WinkBridgeRequest) async throws
        -> (request: WinkBridgeAttestedOperationRequest, refusal: WinkBridgeOperationSessionRefusal)
    {
        let payload = self.request(authority: authority, sequence: sequence, request: request)
        guard case let .rolloverRequired(refusal) = try await authority.claim(payload, peer: self.peer) else {
            throw OperationReceiptSessionFixtureError.expectedRolloverRefusal
        }
        return (payload, refusal)
    }

    static func receiptPayload(
        authority: WinkBridgeOperationReceiptAuthority,
        claim: WinkBridgeOperationSessionClaim,
        request: WinkBridgeRequest,
        response: WinkBridgeResponse,
        operation: WinkBridgeOperation? = nil,
        target: WinkBridgeOperationTargetReceipt? = .global,
        focusedElement: FocusedElementIdentity? = nil,
        targetAttributionFailure: WinkBridgeTargetAttributionFailure? = nil,
        targetAttributionEvidence: [WinkBridgeOperationTargetEvidence]? = nil,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil,
        outcome: DesktopActionOutcome.Projection? = nil) throws -> WinkBridgeOperationReceiptPayload
    {
        let now = WinkBridgeOperationReceiptCoding.unixMilliseconds()
        return try WinkBridgeOperationReceiptPayload(
            requestID: claim.requestID,
            sessionID: claim.sessionID,
            sessionSequence: claim.sessionSequence,
            sessionAttestationSHA256: WinkBridgeOperationReceiptCoding.sha256(
                claim.sessionAttestation),
            listenerInstanceID: authority.attestation.listenerInstanceID,
            listenerPublicKeySHA256: WinkBridgeOperationReceiptCoding.sha256(
                authority.attestation.publicKey),
            host: authority.attestation.host,
            clientInstanceID: claim.sessionAttestation.clientInstanceID,
            client: claim.sessionAttestation.client,
            operation: operation ?? request.operation,
            requestSHA256: WinkBridgeOperationReceiptCoding.sha256(request),
            responseSHA256: WinkBridgeOperationReceiptCoding.sha256(response),
            target: target,
            focusedElement: focusedElement,
            targetAttributionFailure: targetAttributionFailure,
            targetAttributionEvidence: targetAttributionEvidence,
            selectedLeafEvidence: selectedLeafEvidence,
            outcome: outcome,
            remainingClaimCount: claim.remainingClaimCount,
            startedAtUnixMilliseconds: now,
            completedAtUnixMilliseconds: now)
    }

    func signedBundle(
        authority: WinkBridgeOperationReceiptAuthority,
        sequence: UInt64,
        request: WinkBridgeRequest,
        response: WinkBridgeResponse,
        operation: WinkBridgeOperation? = nil,
        target: WinkBridgeOperationTargetReceipt? = .global,
        focusedElement: FocusedElementIdentity? = nil,
        targetAttributionFailure: WinkBridgeTargetAttributionFailure? = nil,
        targetAttributionEvidence: [WinkBridgeOperationTargetEvidence]? = nil,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil,
        outcome: DesktopActionOutcome.Projection? = nil) async throws -> WinkBridgeOperationReceiptBundle
    {
        let accepted = try await self.acceptedClaim(
            authority: authority,
            sequence: sequence,
            request: request)
        let payload = try Self.receiptPayload(
            authority: authority,
            claim: accepted.claim,
            request: request,
            response: response,
            operation: operation,
            target: target,
            focusedElement: focusedElement,
            targetAttributionFailure: targetAttributionFailure,
            targetAttributionEvidence: targetAttributionEvidence,
            selectedLeafEvidence: selectedLeafEvidence,
            outcome: outcome)
        let receipt = try await authority.signAndArchive(payload, claim: accepted.claim)
        let bundle = try Self.bundle(
            authority: authority,
            sessionAttestation: self.attestation,
            receipt: receipt,
            request: request,
            response: response)
        authority.complete(accepted.claim)
        return bundle
    }

    static func bundle(
        authority: WinkBridgeOperationReceiptAuthority,
        sessionAttestation: WinkBridgeOperationSessionAttestation,
        receipt: WinkBridgeOperationReceipt,
        request: WinkBridgeRequest,
        response: WinkBridgeResponse) throws -> WinkBridgeOperationReceiptBundle
    {
        try WinkBridgeOperationReceiptBundle(
            operationAttestation: authority.attestation,
            operationSessionAttestation: sessionAttestation,
            receipt: receipt,
            canonicalListenerAttestationPayload: WinkBridgeOperationReceiptCoding.canonicalData(
                authority.attestation.unsignedPayload),
            canonicalSessionAttestationPayload: WinkBridgeOperationReceiptCoding.canonicalData(
                sessionAttestation.unsignedPayload),
            canonicalReceiptPayload: WinkBridgeOperationReceiptCoding.canonicalData(receipt.payload),
            canonicalRequest: WinkBridgeOperationReceiptCoding.canonicalData(request),
            canonicalResponse: WinkBridgeOperationReceiptCoding.canonicalData(response))
    }
}
