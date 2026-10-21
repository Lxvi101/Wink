import Security

/// Release-signing classification and installation guidance shared by Bridge trust policy.
public enum WinkBridgeSigningDiagnostics {
    public static func isReleaseSigned(
        teamIdentifier: String?,
        isAdHoc: Bool,
        isAppleAnchored: Bool) -> Bool
    {
        guard isAppleAnchored, !isAdHoc, let teamIdentifier else { return false }
        return WinkBridgeConstants.trustedReleaseTeamIDs.contains(teamIdentifier)
    }

    public static func currentProcessIsReleaseSigned() -> Bool {
        let information = WinkBridgeCodeSignatureIdentity.authenticatedCurrentProcessSigningInformation()
        let flags = information?[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        return self.isReleaseSigned(
            teamIdentifier: information?[kSecCodeInfoTeamIdentifier as String] as? String,
            isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0,
            isAppleAnchored: information != nil)
    }

    public static let unsignedBuildHint =
        "This wink binary is not release-signed (for example Homebrew core's source-built `wink` formula " +
        "or a local `swift build`), so Wink Bridge and daemon hosts cannot trust it; install the notarized CLI " +
        "with `brew install openclaw/tap/peekaboo` or `npm i -g wink`."

    public static func appendingUnsignedBuildHint(
        to message: String,
        currentProcessIsReleaseSigned: Bool = WinkBridgeSigningDiagnostics
            .currentProcessIsReleaseSigned()) -> String
    {
        guard !currentProcessIsReleaseSigned, !message.contains(self.unsignedBuildHint) else { return message }
        return message + " " + self.unsignedBuildHint
    }
}
