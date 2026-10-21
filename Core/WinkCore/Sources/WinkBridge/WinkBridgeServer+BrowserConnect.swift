import Foundation
import WinkAutomationKit
import WinkFoundation

@MainActor
extension WinkBridgeServer {
    static func browserHandoffReservationID(
        request: WinkBridgeRequest,
        requestID: UUID) -> UUID?
    {
        guard case let .browserConnect(connect) = request.unwrappedOperationRequest,
              connect.requestsHandoff
        else { return nil }
        return requestID
    }

    func abandonBrowserHandoffReservation(_ requestID: UUID?) {
        guard let requestID,
              let authorizationID = self.browserHandoffGrantRegistry.abandonReservation(requestID: requestID),
              let provider = self.browserSessionBootstrapProvider
        else { return }
        Task { @MainActor in
            await provider.discardBrowserConnectionHandoffAuthorization(authorizationID)
        }
    }

    func handleBrowserConnect(
        _ payload: WinkBridgeBrowserChannelRequest) async throws -> WinkBridgeHandledResponse
    {
        if payload.requestsHandoff {
            guard payload.sessionID == nil else {
                throw WinkBridgeErrorEnvelope(
                    code: .invalidRequest,
                    message: "A scoped browser connect cannot mint another handoff grant")
            }
            guard let operation = WinkBridgeRequestContext.browserHandoffOperation else {
                throw WinkBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "Browser handoff intent requires an attested operation context")
            }
            try await self.browserHandoffGrantRegistry.reserve(
                requestID: operation.requestID,
                issuer: operation.peer.browserSessionCaller(
                    clientInstanceID: operation.clientInstanceID))
        }
        let result: DesktopActionResult<WinkBridgeBrowserStatus>
        if let sessionID = payload.sessionID {
            let caller = try self.authenticatedBrowserSessionCaller()
            let lease = try await self.browserHandoffGrantRegistry.authorizeSession(sessionID, caller: caller)
            defer { self.browserHandoffGrantRegistry.completeSessionOperation(lease) }
            guard let provider = self.browserSessionBootstrapProvider else {
                throw WinkBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "This Bridge host has no scoped browser session provider")
            }
            result = try await provider.browserSessionConnect(
                sessionID: sessionID,
                channel: payload.channel,
                browserURL: payload.browserURL)
            guard result.payload.isCanonicalScopedSessionStatus else {
                throw WinkBridgeErrorEnvelope(
                    code: .internalError,
                    message: "Scoped browser connect returned contradictory status evidence")
            }
        } else {
            result = try await self.browserConnectionResult(payload)
        }
        guard result.payload.isConnected,
              let receipt = result.payload.connectionReceipt,
              let outcome = result.outcome
        else {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .browserProtocol, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Browser connect returned without a live receipt and canonical outcome.",
                hint: "Check browser status before deciding whether to reconnect.")
        }
        guard receipt.matchesConnectRequest(payload) else {
            throw DesktopActionFailure.indeterminate(
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "Browser connect returned a connection receipt for a different endpoint or channel.",
                hint: "Check browser status before deciding whether to reconnect and update the runtime host.")
        }
        let policy = DesktopActionOutcome.SuccessPolicy.confirmedNoChangeOrDispatched(
            requiring: .init(mechanism: .browserProtocol, mode: .foreground),
            unitCount: .exact(.one))
        guard outcome.isAccepted(by: policy) else {
            throw Self.invalidBrowserConnectOutcome(outcome)
        }
        if payload.requestsHandoff {
            guard let operation = WinkBridgeRequestContext.browserHandoffOperation,
                  let provider = self.browserSessionBootstrapProvider
            else {
                throw WinkBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "This Bridge host cannot authorize a browser handoff")
            }
            let authorizationID = try await provider.authorizeBrowserConnectionHandoff(receipt)
            do {
                try self.browserHandoffGrantRegistry.attachAuthorization(
                    requestID: operation.requestID,
                    authorizationID: authorizationID)
            } catch {
                await provider.discardBrowserConnectionHandoffAuthorization(authorizationID)
                throw error
            }
        }
        return try .init(
            response: .browserStatus(result.payload),
            mutation: .init(
                outcome: outcome.routed(to: .bridge),
                target: self.browserTargetDisposition(receipt)))
    }

    func browserConnectionResult(
        _ payload: WinkBridgeBrowserChannelRequest) async throws
        -> DesktopActionResult<WinkBridgeBrowserStatus>
    {
        guard let provider = self.services as? any WinkBridgeBrowserConnectionResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "The Bridge browser provider cannot report canonical connection outcomes.",
                hint: "Update the runtime host before retrying browser connect.")
        }
        return try await provider.browserConnectResult(
            channel: payload.channel,
            browserURL: payload.browserURL)
    }

    func legacyBrowserConnectionStatus(
        _ payload: WinkBridgeBrowserChannelRequest) async throws -> WinkBridgeBrowserStatus
    {
        if self.services is any WinkBridgeBrowserConnectionResultProviding {
            return try await self.browserConnectionResult(payload).payload
        }
        return try await self.services.browserConnect(
            channel: payload.channel,
            browserURL: payload.browserURL)
    }

    func browserTargetDisposition(
        _ receipt: WinkBridgeBrowserConnectionReceipt) throws
        -> WinkBridgeHandledResponse.Mutation.TargetDisposition
    {
        if receipt.isCanonicalProcessBoundTarget,
           WinkBridgeRequestContext.negotiatedSessionCapabilities?
               .nativeBrowserConnectionBinding != true
        {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "Process-bound browser receipts require native browser connection binding.",
                hint: "Update both Wink client and Bridge host before retrying.")
        }
        if let processIdentity = receipt.localProcessIdentity {
            guard receipt.isCanonicalLocalProcessTarget || receipt.isCanonicalProcessBoundTarget else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "The browser connection has an incomplete process-bound DevTools identity.",
                    hint: "Reconnect the intended browser and retry with its full connection receipt.")
            }
            guard
                self.processStartIdentityProvider(processIdentity.processIdentifier)
                == processIdentity.processStartIdentity
            else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "The browser process generation changed before execution.",
                    hint: "Refresh browser status and retry against its new connection receipt.")
            }
            let identity = try DesktopTargetIdentity(processIdentity: processIdentity)
            return .handlerResolved(identity)
        }
        guard receipt.isCanonicalExternalTarget else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The browser connection has no complete process or DevTools identity.",
                hint: "Reconnect the intended browser and retry with its full connection receipt.")
        }
        return .externalBrowser(receipt)
    }

    func browserExecutionTarget(
        _ payload: WinkBridgeBrowserExecuteRequest) async throws
        -> (
            receipt: WinkBridgeBrowserConnectionReceipt,
            disposition: WinkBridgeHandledResponse.Mutation.TargetDisposition)
    {
        let expectedReceipt = try Self.validatedBrowserExecutionReceipt(payload)
        let status: WinkBridgeBrowserStatus
        do {
            status = try await self.services.browserStatus(channel: payload.channel)
        } catch is CancellationError {
            throw Self.browserPreDispatchCancellationFailure()
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch let envelope as WinkBridgeErrorEnvelope {
            if let failure = envelope.desktopActionFailure {
                throw failure
            }
            if envelope.code == .operationNotSupported {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .operationUnsupported,
                    message: envelope.message,
                    hint: "Use a browser provider that supports exact receipt-bound execution.",
                    causeDescription: envelope.details)
            }
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The exact browser connection could not be inspected before execution.",
                hint: "Reconnect the intended browser and retry.",
                causeDescription: envelope.localizedDescription)
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The exact browser connection could not be inspected before execution.",
                hint: "Reconnect the intended browser and retry.",
                causeDescription: error.localizedDescription)
        }
        guard status.isConnected, let receipt = status.connectionReceipt else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Browser execution requires a live exact connection receipt.",
                hint: "Connect the intended browser and retry.")
        }
        guard payload.channel == nil || receipt.channel == payload.channel else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The connected browser channel changed before execution.",
                hint: "Refresh browser status and retry against its exact channel.")
        }
        guard expectedReceipt == receipt else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The exact browser connection changed before execution.",
                hint: "Refresh browser status and retry against its complete connection receipt.")
        }
        return try (receipt, self.browserTargetDisposition(receipt))
    }

    static func validatedBrowserExecutionReceipt(
        _ payload: WinkBridgeBrowserExecuteRequest) throws
        -> WinkBridgeBrowserConnectionReceipt
    {
        guard let receipt = payload.expectedConnectionReceipt,
              receipt.isCanonicalExecutionTarget,
              payload.channel == nil || payload.channel == receipt.channel,
              payload.connectionPolicy == .requireExistingLiveReceipt
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Browser execution requires one complete existing-connection-only receipt.",
                hint: "Refresh browser status and bind the request to its exact connection before retrying.")
        }
        return receipt
    }

    private static func invalidBrowserConnectOutcome(_ outcome: DesktopActionOutcome) -> DesktopActionFailure {
        .indeterminate(
            delivery: outcome.delivery,
            evidence: .completionUnknown,
            unitCount: outcome.dispatchState.unitCount,
            message: "Browser connect returned contradictory canonical action semantics.",
            hint: "Check browser status before deciding whether to reconnect and update the runtime host.")
    }

    private static func browserPreDispatchCancellationFailure() -> DesktopActionFailure {
        .preDispatchRefusal(
            reason: .requestCancelled,
            message: "Browser execution was cancelled before tool dispatch.",
            hint: "Submit a new request only if the browser action is still wanted.")
    }
}
