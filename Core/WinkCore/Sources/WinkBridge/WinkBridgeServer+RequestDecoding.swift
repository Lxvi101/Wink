import Foundation
import os.log
import WinkFoundation

@MainActor
extension WinkBridgeServer {
    public func decodeAndHandle(_ requestData: Data, peer: WinkBridgePeer?) async -> Data {
        do {
            let request = try self.decodeRequest(requestData)
            return await self.handleDecoded(request, peer: peer)
        } catch {
            return self.encodeDecodingFailure(error)
        }
    }

    /// Security boundary: request `Decodable` implementations are value-only. They must not perform I/O, Security
    /// validation, authority mutation, or desktop dispatch. The host authorizes and dispatches this exact returned
    /// value; it must never parse a second representation of the same wire bytes.
    func decodeRequest(_ requestData: Data) throws -> WinkBridgeRequest {
        #if DEBUG
        self.requestDecodeObserverForTesting?()
        #endif
        try WinkBridgeRequestPreflight.validate(requestData)
        return try self.decoder.decode(WinkBridgeRequest.self, from: requestData)
    }

    func handleDecoded(_ request: WinkBridgeRequest, peer: WinkBridgePeer?) async -> Data {
        do {
            if case let .attestedOperation(payload) = request {
                return try await self.handleAttestedOperation(payload, peer: peer)
            }
            if case let .projectedAction(payload) = request {
                return await self.handleProjectedAction(payload, peer: peer)
            }
            let handled = try await self.route(request, peer: peer)
            return try self.encoder.encode(handled.response.projectingScreenCaptureKitDiagnostics(offered: false)
                .projectingSetValueVerification(offered: false, request: request))
        } catch let envelope as WinkBridgeErrorEnvelope {
            self.logger.error("bridge request failed code=\(envelope.code.rawValue, privacy: .public)")
            return WinkBridgeResponse.encodeError(envelope.legacyCompatible, using: self.encoder)
        } catch is CancellationError {
            self.logger.debug("bridge request cancelled after its client disconnected")
            let envelope = WinkBridgeErrorEnvelope(
                code: .timeout,
                message: "Bridge request was cancelled")
            return WinkBridgeResponse.encodeError(envelope, using: self.encoder)
        } catch {
            return self.encodeDecodingFailure(error)
        }
    }

    func encodeAdmissionRefusal(
        _ request: WinkBridgeRequest,
        peer: WinkBridgePeer) async -> Data
    {
        #if DEBUG
        await self.admissionRefusalObserverForTesting?()
        #endif
        do {
            if case let .attestedOperation(payload) = request {
                return try await self.handleAttestedOperation(
                    payload,
                    peer: peer,
                    admissionRefused: true)
            }
            return try self.encoder.encode(Self.admissionRefusalResponse(for: request))
        } catch let envelope as WinkBridgeErrorEnvelope {
            return WinkBridgeResponse.encodeError(envelope.legacyCompatible, using: self.encoder)
        } catch {
            return self.encodeDecodingFailure(error)
        }
    }

    static func admissionRefusalResponse(
        for request: WinkBridgeRequest) throws -> WinkBridgeResponse
    {
        let semanticRequest: WinkBridgeRequest = if case let .projectedAction(payload) = request {
            try payload.validatedRequest()
        } else {
            request
        }
        let message = "Bridge request capacity is temporarily saturated"
        let details = "The decoded request was refused before desktop dispatch."
        let envelope: WinkBridgeErrorEnvelope = if
            WinkBridgeRequestContext.usesAttestedOperationResultSemantics
        {
            .init(
                code: .serverBusy,
                actionFailure: .preDispatchRefusal(
                    route: .bridge,
                    reason: .transportSessionUnavailable,
                    message: message,
                    hint: "Reconnect the Bridge session before retrying.",
                    causeDescription: details),
                details: details)
        } else {
            WinkBridgeOperationResultSemantics.canonicalFailure(
                .init(code: .serverBusy, message: message, details: details),
                request: semanticRequest,
                stage: .preDispatch(.transportSessionUnavailable))
        }
        if case .projectedAction = request {
            return .projectedActionForCurrentRequestVocabulary(
                response: .error(envelope),
                outcome: envelope.actionOutcome)
        }
        return .error(envelope)
    }

    func encodeDecodingFailure(_ error: any Error) -> Data {
        if let envelope = error as? WinkBridgeErrorEnvelope {
            self.logger.error("bridge request failed code=\(envelope.code.rawValue, privacy: .public)")
            return WinkBridgeResponse.encodeError(envelope.legacyCompatible, using: self.encoder)
        }
        self.logger.error("bridge request decoding failed")
        let envelope = WinkBridgeErrorEnvelope(
            code: .decodingFailed,
            message: "Failed to decode request",
            details: "\(error)")
        return WinkBridgeResponse.encodeError(envelope, using: self.encoder)
    }
}
