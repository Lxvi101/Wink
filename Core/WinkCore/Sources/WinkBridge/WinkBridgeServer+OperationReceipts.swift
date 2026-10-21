import Foundation
import WinkAutomationKit
import WinkFoundation

private struct OperationReceiptEncodingContext {
    let request: WinkBridgeRequest
    let plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan
    let requestPayload: WinkBridgeAttestedOperationRequest
    let authority: WinkBridgeOperationReceiptAuthority
    let claim: WinkBridgeOperationSessionClaim
    let startedAt: Int64
}

private struct OperationReceiptTargetState {
    let target: WinkBridgeOperationTargetReceipt?
    let focusedElement: FocusedElementIdentity?
    let failure: WinkBridgeTargetAttributionFailure?
    let failureEvidence: [WinkBridgeOperationTargetEvidence]?
}

private enum OperationReceiptRequestCarriage {
    case valid(WinkBridgeRequest)
    case invalidProjected(any Error)
}

@MainActor
extension WinkBridgeServer {
    func handleAttestedOperation(
        _ payload: WinkBridgeAttestedOperationRequest,
        peer: WinkBridgePeer?,
        admissionRefused: Bool = false) async throws -> Data
    {
        var operationMayHaveCompleted = false
        do {
            return try await self.performAttestedOperation(
                payload,
                peer: peer,
                admissionRefused: admissionRefused,
                operationMayHaveCompleted: &operationMayHaveCompleted)
        } catch let envelope as WinkBridgeErrorEnvelope {
            throw envelope
        } catch {
            let operation = payload.request.operation.rawValue
            let reason = error.localizedDescription
            self.logger.error(
                """
                bridge op=\(operation, privacy: .public) could not produce a signed receipt: \(reason, privacy: .public)
                """)
            throw WinkBridgeErrorEnvelope(
                code: .internalError,
                message: "Bridge host could not produce a signed receipt for \(operation): \(reason)",
                details: reason,
                operationMayHaveCompleted: operationMayHaveCompleted)
        }
    }

    // Attested execution deliberately keeps claim, target, signing, and handoff reservation cleanup in one scope.
    // swiftlint:disable:next function_body_length
    private func performAttestedOperation(
        _ payload: WinkBridgeAttestedOperationRequest,
        peer: WinkBridgePeer?,
        admissionRefused: Bool,
        operationMayHaveCompleted: inout Bool) async throws -> Data
    {
        guard let authority = WinkBridgeRequestContext.operationReceiptAuthority else {
            throw WinkBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "This Bridge listener does not support attested operation receipts")
        }
        guard let peer else {
            throw WinkBridgeErrorEnvelope(
                code: .unauthorizedClient,
                message: "Attested Bridge operations require an authenticated socket peer")
        }
        let requestCarriage = try Self.validateOperationReceiptRequestCarriage(payload)
        let claim: WinkBridgeOperationSessionClaim
        do {
            switch try await authority.claim(payload, peer: peer) {
            case let .accepted(acceptedClaim):
                claim = acceptedClaim
            case let .rolloverRequired(refusal):
                return try self.encoder.encode(WinkBridgeResponse.operationSessionRollover(refusal))
            }
        } catch let error as WinkBridgeOperationReceiptError {
            let code = Self.operationReceiptClaimErrorCode(error)
            throw WinkBridgeErrorEnvelope(code: code, message: error.localizedDescription)
        }
        defer { authority.complete(claim) }

        let startedAt = WinkBridgeOperationReceiptCoding.unixMilliseconds()
        let request: WinkBridgeRequest
        switch requestCarriage {
        case let .valid(validatedRequest):
            request = validatedRequest
        case let .invalidProjected(error):
            return try await self.encodeInvalidAttestedRequestCarriage(
                error: error,
                payload: payload,
                authority: authority,
                claim: claim,
                startedAt: startedAt)
        }
        let handoffReservationID = Self.browserHandoffReservationID(
            request: request,
            requestID: payload.requestID)
        defer {
            self.abandonBrowserHandoffReservation(handoffReservationID)
        }
        let encodingContext = OperationReceiptEncodingContext(
            request: request,
            plan: WinkBridgeOperationResultSemantics.requestPlan(for: request, vocabulary: .current),
            requestPayload: payload,
            authority: authority,
            claim: claim,
            startedAt: startedAt)
        let plan = encodingContext.plan
        let requestEvidence = plan.target.requestEvidence
        if let compatibilityRefusal = try await self.exactScrollCompatibilityRefusal(request, claim, encodingContext) {
            return compatibilityRefusal
        }
        let requestTarget: DesktopTargetIdentity?
        do {
            requestTarget = try WinkBridgeOperationTargetAttribution.resolveRequest(plan)
        } catch let error as DesktopTargetIdentityError {
            let failure = WinkBridgeTargetAttributionFailure(error, stage: .preDispatch)
            let response = Self.targetAttributionFailureResponse(
                plan: plan,
                failure: failure,
                originalOutcome: nil,
                afterExecution: false)
            return try await self.encodeAttestedResponse(
                response,
                targetState: .init(
                    target: nil,
                    focusedElement: nil,
                    failure: failure,
                    failureEvidence: requestEvidence.map(WinkBridgeOperationTargetEvidence.init)),
                context: encodingContext)
        }
        if admissionRefused {
            let response = try WinkBridgeRequestContext.$usesAttestedOperationResultSemantics
                .withValue(true) {
                    try Self.admissionRefusalResponse(for: request)
                }
            guard WinkBridgeOperationReceiptSemantics.allowsTargetlessFailureReceipt(for: response) else {
                throw WinkBridgeErrorEnvelope(
                    code: .internalError,
                    message: "Bridge admission refusal did not produce canonical no-dispatch semantics")
            }
            return try await self.encodeAttestedResponse(
                response,
                targetState: .init(
                    target: nil,
                    focusedElement: nil,
                    failure: nil,
                    failureEvidence: nil),
                context: encodingContext)
        }

        let handled = await self.executeAttestedOperation(plan: plan, claim: claim, peer: peer)
        operationMayHaveCompleted = plan.result.completion.mutatesDesktop &&
            !WinkBridgeOperationResultSemantics.isNoDispatchFailure(handled.response)
        let response: WinkBridgeResponse
        let target: WinkBridgeOperationTargetReceipt?
        let focusedElement: FocusedElementIdentity?
        let targetFailure: WinkBridgeTargetAttributionFailure?
        let targetFailureEvidence: [WinkBridgeOperationTargetEvidence]?
        let attributionEvidence = WinkBridgeOperationTargetAttribution.evidence(
            plan: plan,
            response: handled.response,
            handledTarget: handled.targetIdentity ?? requestTarget)
        do {
            try WinkBridgeOperationResultSemantics.validateSuccessfulTargetDisposition(
                plan: plan,
                handled: handled)
            if WinkBridgeOperationReceiptSemantics.allowsTargetlessFailureReceipt(for: handled.response) {
                response = handled.response
                target = nil
                focusedElement = nil
            } else if let browserReceipt = handled.externalBrowserTarget,
                      !WinkBridgeOperationResultSemantics.isNoDispatchFailure(handled.response)
            {
                guard browserReceipt.isCanonicalExternalTarget,
                      handled.response.browserExecutionConnectionReceipt == browserReceipt
                else {
                    throw DesktopTargetIdentityError.incompleteExactWindow
                }
                response = handled.response
                target = .browser(browserReceipt)
                focusedElement = nil
            } else {
                let resolved = try WinkBridgeOperationTargetAttribution.resolve(
                    plan: plan,
                    response: handled.response,
                    handledTarget: handled.targetIdentity ?? requestTarget)
                let receiptTarget = WinkBridgeResolvedOperationTarget(resolved)
                response = handled.response
                target = receiptTarget.target
                focusedElement = receiptTarget.focusedElement
            }
            targetFailure = nil
            targetFailureEvidence = nil
        } catch let error as DesktopTargetIdentityError {
            let failure = WinkBridgeTargetAttributionFailure(error, stage: .postExecution)
            response = Self.targetAttributionFailureResponse(
                plan: plan,
                failure: failure,
                originalOutcome: handled.outcome?.projection ??
                    WinkBridgeOperationReceiptSemantics.outcome(in: handled.response),
                originalFailure: WinkBridgeOperationResultSemantics.actionFailure(in: handled.response),
                afterExecution: true)
            target = nil
            focusedElement = nil
            targetFailure = failure
            targetFailureEvidence = attributionEvidence.map(WinkBridgeOperationTargetEvidence.init)
        }
        return try await self.encodeAttestedResponse(
            response,
            targetState: .init(
                target: target,
                focusedElement: focusedElement,
                failure: targetFailure,
                failureEvidence: targetFailureEvidence),
            selectedLeafEvidence: targetFailure == nil ? handled.selectedLeafEvidence : nil,
            context: encodingContext)
    }

    private func exactScrollCompatibilityRefusal(
        _ request: WinkBridgeRequest,
        _ claim: WinkBridgeOperationSessionClaim,
        _ context: OperationReceiptEncodingContext) async throws -> Data?
    {
        guard request.requiresRequestPinnedExactWindowScrollReceipt,
              !Self.isBackgroundScrollRuntimeCompatible(request, capabilities: claim.negotiatedCapabilities)
        else { return nil }
        return try await self.encodeAttestedResponse(
            Self.requestPinnedExactWindowScrollRuntimeRefusal(plan: context.plan),
            targetState: .init(
                target: nil,
                focusedElement: nil,
                failure: nil,
                failureEvidence: nil),
            context: context)
    }

    private func executeAttestedOperation(
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan,
        claim: WinkBridgeOperationSessionClaim,
        peer: WinkBridgePeer) async -> WinkBridgeHandledResponse
    {
        if plan.request.requiresCompositeTypeDeliverySupport,
           !claim.negotiatedCapabilities.compositeTypeDelivery
        {
            return Self.compositeTypeDeliveryRefusal(plan: plan)
        }
        let operationContext = WinkBridgeBrowserHandoffOperationContext(
            requestID: claim.requestID,
            clientInstanceID: claim.sessionAttestation.clientInstanceID,
            peer: peer)
        let handled = await WinkBridgeRequestContext.$negotiatedSessionCapabilities.withValue(
            claim.negotiatedCapabilities)
        {
            await WinkBridgeRequestContext.$browserHandoffOperation.withValue(operationContext) {
                await WinkBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                    await self.terminalResponse(for: plan, peer: peer)
                }
            }
        }
        // This is the single enrichment boundary for attested read-only errors. Existing precise
        // envelopes pass through unchanged; only metadata-less targetless failures are normalized.
        return Self.normalizingTargetlessReadOnlyFailure(handled, plan: plan)
    }

    private static func compositeTypeDeliveryRefusal(
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan) -> WinkBridgeHandledResponse
    {
        let failure = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .runtimeIncompatible,
            message: "This Bridge session cannot return truthful composite background typing receipts.",
            hint: "Update and relaunch Wink before retrying background clear-and-type input.")
        let envelope = WinkBridgeErrorEnvelope(
            code: .operationNotSupported,
            actionFailure: failure,
            details: "Bridge protocol 1.36 composite type delivery was not negotiated.")
        if case .projectedAction = plan.carriageRequest {
            return self.projectedFailure(envelope, mayMutateDesktop: true)
        }
        return .init(response: .error(envelope))
    }

    static func operationReceiptClaimErrorCode(
        _ error: WinkBridgeOperationReceiptError) -> WinkBridgeErrorCode
    {
        switch error {
        case .replayedRequest, .listenerInstanceMismatch, .clientIdentityMismatch:
            .invalidRequest
        case .operationSessionRegistryExhausted, .archiveWriteFailed,
             .invalidOperationSessionConfiguration:
            .serverBusy
        default:
            .unauthorizedClient
        }
    }

    private func encodeAttestedResponse(
        _ response: WinkBridgeResponse,
        targetState: OperationReceiptTargetState,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil,
        context: OperationReceiptEncodingContext) async throws -> Data
    {
        // Shipped clients reconstruct the digest after decoding. Project unknown fields before hashing or signing.
        let response = try response.projectingScreenCaptureKitDiagnostics(
            offered: context.claim.negotiatedCapabilities.screenCaptureKitOwnershipDiagnostics)
            .projectingSetValueVerification(
                offered: context.claim.negotiatedCapabilities.setValueVerification, request: context.request)
        let receiptPayload = try WinkBridgeOperationReceiptPayload(
            requestID: context.requestPayload.requestID,
            sessionID: context.requestPayload.sessionID,
            sessionSequence: context.requestPayload.sessionSequence,
            sessionAttestationSHA256: WinkBridgeOperationReceiptCoding.sha256(
                context.claim.sessionAttestation),
            listenerInstanceID: context.authority.attestation.listenerInstanceID,
            listenerPublicKeySHA256: WinkBridgeOperationReceiptCoding.sha256(
                context.authority.attestation.publicKey),
            host: context.authority.attestation.host,
            clientInstanceID: context.requestPayload.clientInstanceID,
            client: context.requestPayload.client,
            operation: context.request.operation,
            requestSHA256: WinkBridgeOperationReceiptCoding.sha256(context.request),
            responseSHA256: WinkBridgeOperationReceiptCoding.sha256(response),
            target: targetState.target,
            focusedElement: targetState.focusedElement,
            targetAttributionFailure: targetState.failure,
            targetAttributionEvidence: targetState.failureEvidence,
            selectedLeafEvidence: selectedLeafEvidence,
            outcome: WinkBridgeOperationReceiptSemantics.outcome(in: response),
            remainingClaimCount: context.claim.remainingClaimCount,
            startedAtUnixMilliseconds: context.startedAt,
            completedAtUnixMilliseconds: max(
                context.startedAt,
                WinkBridgeOperationReceiptCoding.unixMilliseconds()))
        try WinkBridgeOperationReceiptSemantics.validateReceiptCarriage(
            receiptPayload,
            plan: context.plan,
            response: response)
        let receipt = try await context.authority.signAndArchive(receiptPayload, claim: context.claim)
        if case let .browserConnect(connectRequest) = context.request.unwrappedOperationRequest,
           connectRequest.requestsHandoff,
           let connectionReceipt = response.browserExecutionConnectionReceipt,
           connectionReceipt.isCanonicalExecutionTarget
        {
            let bundle = try WinkBridgeOperationReceiptBundle(
                operationAttestation: context.authority.attestation,
                operationSessionAttestation: context.claim.sessionAttestation,
                receipt: receipt,
                canonicalListenerAttestationPayload: WinkBridgeOperationReceiptCoding.canonicalData(
                    context.authority.attestation.unsignedPayload),
                canonicalSessionAttestationPayload: WinkBridgeOperationReceiptCoding.canonicalData(
                    context.claim.sessionAttestation.unsignedPayload),
                canonicalReceiptPayload: WinkBridgeOperationReceiptCoding.canonicalData(receipt.payload),
                canonicalRequest: WinkBridgeOperationReceiptCoding.canonicalData(context.request),
                canonicalResponse: WinkBridgeOperationReceiptCoding.canonicalData(response))
            try self.browserHandoffGrantRegistry.finalize(
                requestID: context.requestPayload.requestID,
                receiptBundle: bundle,
                connectionReceipt: connectionReceipt)
        }
        return try self.encoder.encode(WinkBridgeResponse.attestedOperation(.init(
            response: response,
            receipt: receipt)))
    }

    private static func validateOperationReceiptRequestCarriage(
        _ payload: WinkBridgeAttestedOperationRequest) throws -> OperationReceiptRequestCarriage
    {
        do {
            return try .valid(payload.validatedRequest())
        } catch {
            guard case .projectedAction = payload.request else { throw error }
            return .invalidProjected(error)
        }
    }

    private func encodeInvalidAttestedRequestCarriage(
        error: any Error,
        payload: WinkBridgeAttestedOperationRequest,
        authority: WinkBridgeOperationReceiptAuthority,
        claim: WinkBridgeOperationSessionClaim,
        startedAt: Int64) async throws -> Data
    {
        try await self.encodeAttestedResponse(
            Self.invalidAttestedRequestCarriageResponse(error: error),
            targetState: .init(
                target: nil,
                focusedElement: nil,
                failure: nil,
                failureEvidence: nil),
            context: .init(
                request: payload.request,
                plan: WinkBridgeOperationResultSemantics.requestPlan(
                    for: payload.request,
                    vocabulary: .current),
                requestPayload: payload,
                authority: authority,
                claim: claim,
                startedAt: startedAt))
    }

    private static func invalidAttestedRequestCarriageResponse(error: any Error) -> WinkBridgeResponse {
        let failure = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .invalidRequest,
            message: "Bridge operation request carriage is invalid.",
            hint: "Rebuild the request with exactly one projected action wrapper.",
            causeDescription: error.localizedDescription)
        let envelope = WinkBridgeErrorEnvelope(
            code: .invalidRequest,
            actionFailure: failure,
            details: error.localizedDescription)
        return .projectedActionForCurrentRequestVocabulary(
            response: .error(envelope),
            outcome: failure.outcome.projection,
            usesCurrentVocabulary: true)
    }

    private static func requestPinnedExactWindowScrollRuntimeRefusal(
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan) -> WinkBridgeResponse
    {
        let envelope = self.requestPinnedExactWindowScrollRuntimeIncompatibleEnvelope(
            requiresCoordinates: plan.request.requiresBackgroundCoordinateScroll)
        guard let failure = envelope.desktopActionFailure else {
            preconditionFailure("Exact-window scroll runtime refusal must carry a canonical action failure")
        }
        if case .projectedAction = plan.carriageRequest {
            return .projectedActionForCurrentRequestVocabulary(
                response: .error(envelope),
                outcome: failure.outcome.projection,
                usesCurrentVocabulary: true)
        }
        return .error(envelope)
    }

    static func isBackgroundScrollRuntimeCompatible(
        _ request: WinkBridgeRequest,
        capabilities: WinkBridgeNegotiatedSessionCapabilities?) -> Bool
    {
        guard let capabilities, capabilities.requestPinnedExactWindowScrollReceipt,
              capabilities.protocolVersion >= WinkBridgeConstants.requestPinnedExactWindowScrollReceiptVersion
        else { return false }
        return !request.requiresBackgroundCoordinateScroll ||
            (capabilities.backgroundCoordinateScroll &&
                capabilities.protocolVersion >= WinkBridgeConstants.backgroundCoordinateScrollVersion)
    }

    static func requestPinnedExactWindowScrollRuntimeIncompatibleEnvelope(
        requiresCoordinates: Bool = false) -> WinkBridgeErrorEnvelope
    {
        let failure = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .runtimeIncompatible,
            message: requiresCoordinates
                ? "This Bridge session does not support background coordinate scroll."
                : "This Bridge session cannot preserve an exact-window scroll receipt.",
            hint: "Update and relaunch Wink before retrying background scroll.")
        return WinkBridgeErrorEnvelope(
            code: .versionMismatch,
            actionFailure: failure,
            context: "bridge_exact_scroll_receipt:runtime_incompatible")
    }

    private func terminalResponse(
        for plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan,
        peer: WinkBridgePeer) async -> WinkBridgeHandledResponse
    {
        let request = plan.carriageRequest
        if case let .projectedAction(payload) = request {
            do {
                _ = try payload.validatedRequest()
                let handled = try await self.route(plan, peer: peer)
                return .init(
                    response: .projectedActionForCurrentRequestVocabulary(
                        response: handled.response,
                        outcome: handled.outcome?.routed(to: .bridge).projection),
                    mutation: handled.mutation,
                    targetIdentity: handled.targetIdentity,
                    selectedLeafEvidence: handled.selectedLeafEvidence)
            } catch let envelope as WinkBridgeErrorEnvelope {
                return Self.projectedFailure(
                    envelope,
                    mayMutateDesktop: plan.result.completion.mutatesDesktop)
            } catch let failure as DesktopActionFailure {
                return Self.projectedFailure(
                    .init(
                        code: .internalError,
                        actionFailure: failure.routed(to: .bridge),
                        details: "\(failure)"),
                    mayMutateDesktop: plan.result.completion.mutatesDesktop)
            } catch is CancellationError {
                return Self.projectedFailure(
                    .init(
                        code: .timeout,
                        message: "Bridge request was cancelled"),
                    mayMutateDesktop: plan.result.completion.mutatesDesktop)
            } catch {
                return Self.projectedFailure(
                    .init(
                        code: .internalError,
                        message: error.localizedDescription,
                        details: "\(error)"),
                    mayMutateDesktop: plan.result.completion.mutatesDesktop)
            }
        }
        do {
            return try await self.route(plan, peer: peer)
        } catch let envelope as WinkBridgeErrorEnvelope {
            let responseEnvelope = WinkBridgeRequestContext.usesAttestedOperationResultSemantics
                ? Self.canonicalMutationFailureEnvelope(
                    envelope,
                    mayMutateDesktop: plan.result.completion.mutatesDesktop)
                : envelope.legacyCompatible
            return .init(
                response: .error(responseEnvelope),
                selectedLeafEvidence: responseEnvelope.actionSelectedLeafEvidence)
        } catch let failure as DesktopActionFailure
            where WinkBridgeRequestContext.usesAttestedOperationResultSemantics
        {
            let routed = failure.routed(to: .bridge)
            return .init(
                response: .error(.init(
                    code: .internalError,
                    actionFailure: routed,
                    details: "\(failure)")),
                selectedLeafEvidence: routed.selectedLeafEvidence)
        } catch is CancellationError {
            return .init(response: .error(Self.canonicalMutationFailureEnvelope(
                .init(code: .timeout, message: "Bridge request was cancelled"),
                mayMutateDesktop: plan.result.completion.mutatesDesktop)))
        } catch {
            return .init(response: .error(Self.canonicalMutationFailureEnvelope(
                .init(
                    code: .internalError,
                    message: error.localizedDescription,
                    details: "\(error)"),
                mayMutateDesktop: plan.result.completion.mutatesDesktop)))
        }
    }

    private static func targetlessReadOnlyFailureEnvelope(
        _ envelope: WinkBridgeErrorEnvelope,
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan) -> WinkBridgeErrorEnvelope
    {
        guard !plan.result.completion.mutatesDesktop,
              !envelope.operationMayHaveCompleted,
              envelope.actionOutcome == nil,
              envelope.actionTargetReceipt == nil,
              envelope.actionSelectedLeafEvidence == nil
        else {
            return envelope
        }
        let failure = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: self.readOnlyFailureReason(envelope.code),
            message: envelope.message,
            hint: envelope.actionFailureHint,
            causeDescription: envelope.details)
        return WinkBridgeErrorEnvelope(
            code: envelope.code,
            actionFailure: failure.preservingScreenCaptureKitDiagnostic(envelope.screenCaptureKitOwnershipDiagnostic),
            details: envelope.details,
            permission: envelope.permission,
            kind: envelope.kind,
            context: envelope.context)
    }

    private static func normalizingTargetlessReadOnlyFailure(
        _ handled: WinkBridgeHandledResponse,
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan) -> WinkBridgeHandledResponse
    {
        guard case let .error(envelope) = handled.response else { return handled }
        return handled.replacingResponse(.error(self.targetlessReadOnlyFailureEnvelope(envelope, plan: plan)))
    }

    private static func readOnlyFailureReason(
        _ code: WinkBridgeErrorCode) -> DesktopActionOutcome.RefusalReason
    {
        switch code {
        case .permissionDenied:
            .permissionDenied
        case .notFound:
            .targetUnavailable
        case .timeout:
            .requestCancelled
        case .invalidRequest, .decodingFailed:
            .invalidRequest
        case .operationNotSupported:
            .operationUnsupported
        case .serverBusy, .unauthorizedClient:
            .transportSessionUnavailable
        case .versionMismatch, .internalError:
            .runtimeIncompatible
        }
    }

    private static func projectedFailure(
        _ unprojectedEnvelope: WinkBridgeErrorEnvelope,
        mayMutateDesktop: Bool) -> WinkBridgeHandledResponse
    {
        let envelope = self.canonicalMutationFailureEnvelope(
            unprojectedEnvelope,
            mayMutateDesktop: mayMutateDesktop)
        return .init(
            response: .projectedActionForCurrentRequestVocabulary(
                response: .error(envelope),
                outcome: envelope.actionOutcome),
            selectedLeafEvidence: envelope.actionSelectedLeafEvidence)
    }

    private static func canonicalMutationFailureEnvelope(
        _ envelope: WinkBridgeErrorEnvelope,
        mayMutateDesktop: Bool) -> WinkBridgeErrorEnvelope
    {
        guard mayMutateDesktop, envelope.actionOutcome == nil else { return envelope }
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            evidence: .completionUnknown,
            message: envelope.message,
            hint: "Observe the intended target before retrying this operation.",
            causeDescription: envelope.details)
        return WinkBridgeErrorEnvelope(
            code: envelope.code,
            actionFailure: failure.preservingScreenCaptureKitDiagnostic(envelope.screenCaptureKitOwnershipDiagnostic),
            details: envelope.details,
            permission: envelope.permission,
            kind: envelope.kind,
            context: envelope.context)
    }

    private static func targetAttributionFailureResponse(
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan,
        failure: WinkBridgeTargetAttributionFailure,
        originalOutcome: DesktopActionOutcome.Projection?,
        originalFailure: DesktopActionFailure? = nil,
        afterExecution: Bool) -> WinkBridgeResponse
    {
        let context = "bridge_target_attribution:\(failure.code.rawValue)"
        guard plan.result.completion.mutatesDesktop else {
            return .error(.init(
                code: .invalidRequest,
                message: "Bridge operation target attribution failed",
                details: failure.message,
                context: context))
        }

        let original = originalOutcome?.outcome
        let mayHaveDispatched = afterExecution && (original?.dispatchState.mutationDispatched ?? true)
        var diagnostics = [failure.message]
        if let originalFailure {
            // Preserve only caller-facing typed diagnostics, never raw envelope details or target evidence.
            diagnostics.append("Original operation failure: \(originalFailure.message.prefix(512))")
            if let cause = originalFailure.causeDescription, !cause.isEmpty {
                diagnostics.append("Original cause: \(cause.prefix(1536))")
            }
        }
        let causeDescription = diagnostics.joined(separator: "\n")
        let actionFailure: DesktopActionFailure = if mayHaveDispatched {
            .indeterminate(
                route: .bridge,
                delivery: original?.delivery,
                evidence: .completionUnknown,
                unitCount: original?.dispatchState.unitCount,
                message: "Bridge operation completed without a trustworthy exact target receipt.",
                hint: "Observe the intended target before any retry.",
                causeDescription: causeDescription)
        } else {
            .preDispatchRefusal(
                route: .bridge,
                reason: .invalidRequest,
                message: "Bridge operation was refused because its target receipt is invalid.",
                hint: "Capture fresh target evidence and retry with one exact process or window receipt.",
                causeDescription: causeDescription)
        }
        let envelope = WinkBridgeErrorEnvelope(
            code: mayHaveDispatched ? .internalError : .invalidRequest,
            actionFailure: actionFailure,
            context: context)
        if case .projectedAction = plan.carriageRequest {
            return .projectedActionForCurrentRequestVocabulary(
                response: .error(envelope),
                outcome: actionFailure.outcome.projection,
                usesCurrentVocabulary: true)
        }
        return .error(envelope)
    }
}
