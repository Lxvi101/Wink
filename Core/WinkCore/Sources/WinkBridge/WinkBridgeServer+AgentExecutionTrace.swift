import Foundation
import WinkFoundation

@MainActor
extension WinkBridgeServer {
    func handleAgentExecutionTraceRequest(
        _ request: WinkBridgeRequest,
        peer: WinkBridgePeer?) async throws -> WinkBridgeHandledResponse
    {
        let negotiatedVersion = WinkBridgeRequestContext.negotiatedSessionCapabilities?.protocolVersion ??
            .init(major: 0, minor: 0)
        guard WinkBridgeRequestContext.usesAttestedOperationResultSemantics,
              negotiatedVersion >= WinkBridgeConstants.agentExecutionTraceVersion
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Bridge Agent execution requires protocol 1.31 signed operation receipts.",
                hint: "Update and relaunch the Wink Bridge host before retrying.")
        }
        guard case let .agentExecutionTrace(payload) = request else {
            throw Self.invalidRequest(for: request)
        }
        guard let peer, peer.liveIdentity != nil
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .transportSessionUnavailable,
                message: "Bridge Agent execution requires the exact authenticated Wink CLI peer.",
                hint: "Use the signed installed Wink CLI that authenticated this Bridge session.")
        }
        #if DEBUG
        let hasAuthorizedCLIBundle = peer.bundleIdentifier == WinkBridgeConstants.cliBundleIdentifier ||
            self.allowsAuthenticatedAgentExecutionPeerForTesting
        #else
        let hasAuthorizedCLIBundle = peer.bundleIdentifier == WinkBridgeConstants.cliBundleIdentifier
        #endif
        guard hasAuthorizedCLIBundle else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .transportSessionUnavailable,
                message: "Bridge Agent execution requires the exact authenticated Wink CLI peer.",
                hint: "Use the signed installed Wink CLI that authenticated this Bridge session.")
        }
        guard let servingSocketPath = self.servingSocketPath,
              let runner = self.agentExecutionRunner
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "This Bridge host cannot launch authenticated Agent executions.",
                hint: "Use the signed Wink app or daemon Bridge host advertised for Agent execution.")
        }

        let result: WinkBridgeAgentExecutionTraceResponse
        do {
            result = try await runner.run(
                request: payload,
                peer: peer,
                servingSocketPath: servingSocketPath)
        } catch let error as WinkBridgeAgentExecutionPreReleaseError {
            let failure = DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: Self.agentExecutionRefusalReason(error),
                message: error.localizedDescription,
                hint: "Correct the coordination failure before starting another Agent execution.")
            return .init(
                response: .error(.init(
                    code: Self.agentExecutionErrorCode(error),
                    actionFailure: failure,
                    details: error.localizedDescription)),
                mutation: .init(outcome: failure.outcome, target: .global))
        }
        guard let peerStartIdentity = peer.processStartIdentity,
              let peerCodeSignatureHash = peer.codeSignatureHash,
              result.requestingPeer == .init(
                  processIdentifier: peer.processIdentifier,
                  processStartIdentity: peerStartIdentity,
                  codeSignatureHash: peerCodeSignatureHash),
              result.bridgeSocketPath == servingSocketPath
        else {
            throw DesktopActionFailure.indeterminate(
                route: .bridge,
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Bridge Agent execution returned contradictory peer or host authority.",
                hint: "Do not retry; retain the coordination files and inspect the signed host.")
        }
        return .init(
            response: .agentExecutionTrace(result),
            mutation: .init(
                outcome: .dispatchedUnverified(
                    route: .bridge,
                    delivery: .init(mechanism: .nativeFramework, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                target: .responseResolved))
    }

    private static func agentExecutionRefusalReason(
        _ error: WinkBridgeAgentExecutionPreReleaseError) -> DesktopActionOutcome.RefusalReason
    {
        switch error {
        case .invalidRequest, .unsafeRunRoot, .invalidAcknowledgement:
            .invalidRequest
        case .unauthenticatedPeer, .executableIdentityChanged, .acknowledgementTimedOut:
            .transportSessionUnavailable
        case .cancelledBeforeRelease:
            .requestCancelled
        case .spawnFailed, .receiptPublicationFailed, .releaseFailed:
            .runtimeIncompatible
        }
    }

    private static func agentExecutionErrorCode(
        _ error: WinkBridgeAgentExecutionPreReleaseError) -> WinkBridgeErrorCode
    {
        switch error {
        case .invalidRequest, .unsafeRunRoot, .invalidAcknowledgement:
            .invalidRequest
        case .cancelledBeforeRelease, .acknowledgementTimedOut:
            .timeout
        case .unauthenticatedPeer:
            .unauthorizedClient
        case .executableIdentityChanged, .spawnFailed, .receiptPublicationFailed, .releaseFailed:
            .internalError
        }
    }
}
