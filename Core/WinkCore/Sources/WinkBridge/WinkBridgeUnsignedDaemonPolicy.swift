import Darwin
import Foundation

public enum WinkBridgeTrustMode: String, Codable, Sendable {
    case releaseSignature
    case unsignedSameBinaryDeveloperOptIn

    public var description: String {
        switch self {
        case .releaseSignature: "release signature"
        case .unsignedSameBinaryDeveloperOptIn: "unsigned same-binary developer opt-in"
        }
    }
}

/// A local policy only: neither wire metadata nor executable paths can authorize this exception.
struct WinkBridgeUnsignedDaemonPolicy: Sendable {
    let enabled: Bool
    let effectiveUserIdentifier: uid_t
    let codeSignatureHash: String?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentProcessIsReleaseSigned: () -> Bool = WinkBridgeSigningDiagnostics.currentProcessIsReleaseSigned,
        effectiveUserIdentifier: uid_t = geteuid(),
        codeSignatureHash: () -> String? = {
            WinkBridgeCodeSignatureIdentity.codeSignatureHash(processIdentifier: getpid())
        })
    {
        self.enabled = environment["WINK_ALLOW_UNSIGNED_DAEMON"] == "1" && !currentProcessIsReleaseSigned()
        self.effectiveUserIdentifier = effectiveUserIdentifier
        self.codeSignatureHash = self.enabled ? codeSignatureHash() : nil
    }

    func allows(_ peer: WinkBridgeLivePeerIdentity, hostKind: WinkBridgeHostKind?) -> Bool {
        self.enabled && hostKind == .onDemand &&
            peer.effectiveUserIdentifier == self.effectiveUserIdentifier &&
            self.codeSignatureHash?.isEmpty == false && peer.codeSignatureHash == self.codeSignatureHash
    }
}
