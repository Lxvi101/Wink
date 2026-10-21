import Foundation

public struct WinkBridgeCertificationProducerAttestationDelivery: Sendable {
    public let response: WinkBridgeCertificationProducerAttestationResponse
    public let receiptBundle: WinkBridgeOperationReceiptBundle
}

extension WinkBridgeClient {
    public func attestCertificationProducer(
        _ request: WinkBridgeCertificationProducerAttestationRequest) async throws
        -> WinkBridgeCertificationProducerAttestationResponse
    {
        try await self.attestCertificationProducerWithReceipt(request).response
    }

    public func attestCertificationProducerWithReceipt(
        _ request: WinkBridgeCertificationProducerAttestationRequest) async throws
        -> WinkBridgeCertificationProducerAttestationDelivery
    {
        try self.requireCertificationProducerAttestation()
        try request.validate()
        let reply = try await self.sendCarryingActionOutcome(
            .certificationProducerAttestation(request),
            operationReceiptRequirement: .required)
        guard case let .certificationProducerAttestation(response) = reply.response else {
            if case let .error(error) = reply.response {
                throw error
            }
            throw WinkBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected certification producer attestation response")
        }
        guard let receiptBundle = reply.operationReceiptBundle else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("the required certification bundle")
        }
        try response.validate(
            request: request,
            listenerAttestation: receiptBundle.operationAttestation)
        return .init(response: response, receiptBundle: receiptBundle)
    }

    /// Returns the signed terminal bundle even when the producer refused or failed validation.
    public func certificationProducerAttestationReceiptBundle(
        _ request: WinkBridgeCertificationProducerAttestationRequest) async throws
        -> WinkBridgeOperationReceiptBundle
    {
        try self.requireCertificationProducerAttestation()
        try request.validate()
        let reply = try await self.sendCarryingActionOutcome(
            .certificationProducerAttestation(request),
            operationReceiptRequirement: .required,
            throwsActionFailures: false)
        switch reply.response {
        case let .certificationProducerAttestation(response):
            guard let receiptBundle = reply.operationReceiptBundle else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "the required certification bundle")
            }
            try response.validate(
                request: request,
                listenerAttestation: receiptBundle.operationAttestation)
        case .error:
            break
        default:
            throw WinkBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected certification producer attestation response")
        }
        guard let receiptBundle = reply.operationReceiptBundle else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("the required certification bundle")
        }
        try receiptBundle.validateIntegrity()
        return receiptBundle
    }

    private func requireCertificationProducerAttestation() throws {
        guard self.certificationProducerAttestationEnabled else {
            throw WinkBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge protocol 1.32 certification producer attestation is unavailable",
                details: "The host must advertise and enable certificationProducerAttestation before use.")
        }
    }
}
