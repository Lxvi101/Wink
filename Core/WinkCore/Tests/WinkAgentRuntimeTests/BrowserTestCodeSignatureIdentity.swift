import Foundation
import WinkAutomationKit
import WinkFoundation

extension ChromeProcessCodeSignatureValidator.Identity {
    static func browserTestIdentity(
        channel: ChromeChannelIdentity,
        codeDirectoryHash: Data = Data([1])) -> Self
    {
        .init(
            identifier: channel.bundleIdentifier,
            teamIdentifier: ChromeProcessCodeSignatureValidator.googleChromeTeamIdentifier,
            codeDirectoryHash: codeDirectoryHash)
    }
}
