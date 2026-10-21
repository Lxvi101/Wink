import Foundation
import WinkAutomationKit
import WinkFoundation

@MainActor
extension WinkBridgeServer {
    static func requireSuccessfulObservationOutcome(
        _ result: UIAutomationActionResult<DesktopObservationResult>) throws -> DesktopActionOutcome
    {
        guard let outcome = result.outcome else {
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "The desktop observation provider returned without a canonical action outcome.",
                hint: "Observe the target before retrying and update the runtime host.")
        }
        return outcome
    }

    static func observationFailure(
        _ result: UIAutomationActionResult<DesktopObservationResult>,
        outcome: DesktopActionOutcome) -> DesktopActionFailure?
    {
        guard !outcome.isAccepted(by: .observation) else { return nil }
        return DesktopActionFailure(
            outcome: outcome,
            message: "The desktop observation provider reported a non-success action outcome.",
            hint: "Follow the canonical outcome before retrying.",
            targetReceipt: result.targetIdentity?.actionTargetReceipt)
    }

    static func observationFallbackTarget(
        for request: DesktopObservationRequest) -> WinkBridgeHandledResponse.Mutation.TargetDisposition
    {
        switch request.target {
        case .app, .pid, .windowID, .frontmost:
            .responseResolved
        case .screen, .allScreens, .area, .menubar:
            .global
        case .menubarPopover:
            .responseResolved
        }
    }

    static func validateAttestedWebFocusTarget(
        _ request: DesktopObservationRequest) throws
    {
        guard WinkBridgeRequestContext.usesAttestedOperationResultSemantics,
              request.detection.mode != .none,
              request.detection.allowWebFocusFallback
        else {
            return
        }

        switch request.target {
        case .app, .pid, .windowID, .frontmost:
            return
        case .screen, .allScreens, .area, .menubar, .menubarPopover:
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Attested web focus requires an exact application or window target.",
                hint: "Target a concrete app, PID, frontmost window, or window ID; otherwise disable web focus.")
        }
    }

    static func validateAttestedObservationBinding(
        _ request: DesktopObservationRequest,
        result: DesktopObservationResult,
        requireContentDigest: Bool = true) throws
    {
        guard WinkBridgeRequestContext.usesAttestedOperationResultSemantics || request.output.includeImageData,
              let mismatch = WinkBridgeDesktopObservationBinding.mismatch(
                  request: request,
                  result: result,
                  requireContentDigest: requireContentDigest)
        else {
            return
        }
        throw WinkBridgeErrorEnvelope(
            code: .internalError,
            message: "The desktop observation provider returned inconsistent response evidence: \(mismatch).")
    }

    func windowMutationResponse(
        request: WinkBridgeRequest,
        outcome: DesktopActionOutcome?,
        focusReadback: ServiceWindowInfo? = nil) async throws -> WinkBridgeResponse
    {
        guard WinkBridgeRequestContext.usesAttestedOperationResultSemantics,
              let outcome,
              outcome.isConfirmed
        else { return .ok }
        let readback: ServiceWindowInfo?
        do {
            guard let identity = request.pinnedWindowMutation?.identity else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            let rawReadback: ServiceWindowInfo?
            do {
                if request.operation == .focusWindow, let focusReadback {
                    rawReadback = focusReadback
                } else {
                    rawReadback = try await self.services.windows
                        .listWindows(target: .windowId(identity.windowID)).first
                }
            } catch let error as WinkError {
                if [.closeWindow, .backgroundCloseWindow].contains(request.operation),
                   case .windowNotFound = error
                {
                    // Exact-window lookup reports a successful close as target absence.
                    rawReadback = nil
                } else {
                    throw error
                }
            }
            if request.operation == .maximizeWindow, let rawReadback {
                let visibleWorkArea = self.maximizedVisibleWorkAreaProvider(rawReadback.bounds)
                readback = rawReadback.withMutationPostconditionEvidence(.init(
                    isMaximized: visibleWorkArea.map {
                        WindowMutationGeometryPostcondition.boundsMatch(rawReadback.bounds, $0)
                    } ?? false,
                    verifiedVisibleWorkArea: visibleWorkArea))
            } else {
                readback = rawReadback?.withMutationPostconditionEvidence(nil)
            }
            try WinkBridgeOperationReceiptSemantics.validatePostMutationWindow(
                readback,
                request: request,
                outcome: outcome.routed(to: .bridge))
        } catch {
            throw DesktopActionFailure.indeterminate(
                route: .local,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "The confirmed window mutation could not prove its requested postcondition.",
                hint: "Observe the window before retrying.",
                causeDescription: error.localizedDescription)
        }
        return .window(readback)
    }
}
