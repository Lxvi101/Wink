import Foundation

@MainActor
extension WinkBridgeServer {
    func handleCertificationProducerAttestation(
        _ request: WinkBridgeCertificationProducerAttestationRequest) async throws
        -> WinkBridgeCertificationProducerAttestationResponse
    {
        try request.validate()
        guard let listenerAttestation = WinkBridgeRequestContext.operationReceiptAuthority?.attestation else {
            throw WinkBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Certification producer attestation requires signed Bridge operation receipts")
        }
        return try await WinkBridgeBlockingIO.run {
            try WinkBridgeCertificationProducerTransport.perform(
                request: request,
                listenerAttestation: listenerAttestation)
        }
    }
}
