import Foundation

public struct WinkBridgeProcessGenerationObservationDelivery: Sendable {
    public let response: WinkBridgeProcessGenerationObservationResponse
    public let receiptBundle: WinkBridgeOperationReceiptBundle
}

extension WinkBridgeClient {
    public func observeProcessGeneration(
        _ request: WinkBridgeProcessGenerationObservationRequest) async throws
        -> WinkBridgeProcessGenerationObservationResponse
    {
        try await self.observeProcessGenerationWithReceipt(request).response
    }

    public func observeProcessGenerationWithReceipt(
        _ request: WinkBridgeProcessGenerationObservationRequest) async throws
        -> WinkBridgeProcessGenerationObservationDelivery
    {
        try self.requireProcessGenerationObservation()
        try request.validate()
        let reply = try await self.sendCarryingActionOutcome(
            .observeProcessGeneration(request),
            operationReceiptRequirement: .required)
        let response = try Self.validatedProcessGenerationObservationResponse(
            reply.response,
            request: request)
        guard let receiptBundle = reply.operationReceiptBundle else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("the required terminal bundle")
        }
        return .init(response: response, receiptBundle: receiptBundle)
    }

    /// Returns the exact signed bundle even when observation failed without producing a disposition.
    public func observeProcessGenerationReceiptBundle(
        _ request: WinkBridgeProcessGenerationObservationRequest) async throws
        -> WinkBridgeOperationReceiptBundle
    {
        try self.requireProcessGenerationObservation()
        try request.validate()
        let reply = try await self.sendCarryingActionOutcome(
            .observeProcessGeneration(request),
            operationReceiptRequirement: .required,
            throwsActionFailures: false)
        switch reply.response {
        case let .processGenerationObservation(response):
            try response.validate(request: request)
        case .error:
            break
        default:
            throw WinkBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected process-generation observation response")
        }
        guard let receiptBundle = reply.operationReceiptBundle else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("the required terminal bundle")
        }
        try receiptBundle.validateIntegrity()
        return receiptBundle
    }

    private func requireProcessGenerationObservation() throws {
        guard self.processGenerationObservationEnabled else {
            throw WinkBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge protocol 1.32 signed process-generation observation is unavailable",
                details: "The host must advertise and enable observeProcessGeneration before use.")
        }
    }

    private nonisolated static func validatedProcessGenerationObservationResponse(
        _ response: WinkBridgeResponse,
        request: WinkBridgeProcessGenerationObservationRequest) throws
        -> WinkBridgeProcessGenerationObservationResponse
    {
        switch response {
        case let .processGenerationObservation(result):
            try result.validate(request: request)
            return result
        case let .error(envelope):
            throw envelope
        default:
            throw WinkBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected process-generation observation response")
        }
    }
}
