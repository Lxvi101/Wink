import Foundation

enum WinkBridgeConnectedHostTrust {
    @discardableResult
    static func validate(
        _ host: WinkBridgeConnectedHostIdentity?,
        socketPath: String,
        trustedTeamIDs: Set<String>,
        hostKind: WinkBridgeHostKind? = nil,
        unsignedDaemonPolicy: WinkBridgeUnsignedDaemonPolicy = .init(),
        currentProcessIsReleaseSigned: () -> Bool = WinkBridgeSigningDiagnostics
            .currentProcessIsReleaseSigned) throws -> WinkBridgeTrustMode
    {
        let failedCheck: String
        if let host {
            if let liveHash = host.liveIdentity.codeSignatureHash, !liveHash.isEmpty {
                if let signing = host.signingIdentity {
                    if signing.codeSignatureHash != liveHash {
                        failedCheck = "signed executable CDHash does not match the live socket peer"
                    } else if let team = signing.teamIdentifier, trustedTeamIDs.contains(team) {
                        return .releaseSignature
                    } else {
                        failedCheck = "signing Team ID is missing or not trusted"
                    }
                } else {
                    let reason = host.signingIdentityFailure.map { ": " + $0.localizedDescription } ?? ""
                    failedCheck = "Apple-anchored signing identity could not be bound to the live peer" + reason
                }
            } else {
                failedCheck = "live kernel CDHash is unavailable"
            }
        } else {
            failedCheck = "connected socket peer identity is unavailable"
        }
        if let host, unsignedDaemonPolicy.allows(host.liveIdentity, hostKind: hostKind),
           !currentProcessIsReleaseSigned()
        {
            return .unsignedSameBinaryDeveloperOptIn
        }
        let peer = host.map { " (PID \($0.liveIdentity.processIdentifier))" } ?? ""
        let message = "Bridge host authentication failed at '\(socketPath)'\(peer): \(failedCheck). " +
            "Relaunch the released signed host at this socket; if its executable was replaced, " +
            "stop the old host process and restart it from the current signed app or CLI. " +
            "Chrome approval and browser receipts have not been checked."
        var error = WinkBridgeErrorEnvelope(
            code: .unauthorizedClient,
            message: WinkBridgeSigningDiagnostics.appendingUnsignedBuildHint(
                to: message, currentProcessIsReleaseSigned: currentProcessIsReleaseSigned()),
            context: "connectedHostAuthentication")
        error.isLocalHostAuthenticationFailure = true
        throw error
    }
}
