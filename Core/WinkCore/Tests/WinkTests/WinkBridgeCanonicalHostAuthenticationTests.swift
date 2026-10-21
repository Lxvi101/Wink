import Foundation
import WinkBridgeTestSupport
import Testing
@testable import WinkBridge

struct WinkBridgeCanonicalHostAuthenticationTests {
    @Test
    func `signing validation failure reaches the connected host authentication error`() async throws {
        let peer = try ScriptedBridgePeer(responses: [.error(.init(code: .invalidRequest, message: "unused"))])
        let failure = WinkBridgeCodeSignatureIdentity.SigningValidationFailure
            .liveAnchoredRequirementNotSatisfied(-67050)
        let client = WinkBridgeClient(
            socketPath: peer.socketPath,
            requestTimeoutSec: 1,
            trustedHostTeamIDs: ["FWJYW4S8P8"],
            hostAuthentication: .init(signingIdentity: { _ in throw failure }))
        do {
            try await client.handshake(client: .init(
                bundleIdentifier: nil,
                teamIdentifier: nil,
                processIdentifier: ProcessInfo.processInfo.processIdentifier))
            Issue.record("Expected authentication refusal")
        } catch let error as WinkBridgeErrorEnvelope {
            #expect(error.code == .unauthorizedClient)
            #expect(error.isLocalHostAuthenticationFailure)
            #expect(error.message.contains(failure.localizedDescription))
        } catch {
            await peer.stop()
            throw error
        }
        #expect(await peer.acceptedConnectionCount == 1)
        await peer.stop()
    }

    @Test(arguments: ["Y5PE65HELJ", "FWJYW4S8P8", "OTHER-TEAM", "wrong-hash", nil] as [String?])
    func `canonical OpenClaw trust retains connected signer validation`(signer: String?) async throws {
        let canonicalPath = URL(fileURLWithPath: WinkBridgeConstants.winkSocketPath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenClaw/bridge.sock").path
        // Exercise the canonical policy on a test-owned socket, never the installed OpenClaw listener.
        let trustedTeams = try #require(WinkBridgeConstants.defaultTrustedHostTeamIDs(socketPath: canonicalPath))
        let acceptedSigner = signer == "Y5PE65HELJ" || signer == "FWJYW4S8P8"
        let peer = try ScriptedBridgePeer(responses: [
            .error(.init(
                code: acceptedSigner ? .invalidRequest : .versionMismatch,
                message: "A refused signer must not trigger protocol fallback")),
        ])
        let client = WinkBridgeClient(
            socketPath: peer.socketPath,
            requestTimeoutSec: 1,
            trustedHostTeamIDs: trustedTeams,
            hostAuthentication: .init(signingIdentity: { auditIdentity in
                guard let signer,
                      let hash = WinkBridgeCodeSignatureIdentity.codeSignatureHash(auditIdentity: auditIdentity)
                else { return nil }
                return WinkBridgeHost.PeerSigningIdentity(
                    bundleIdentifier: "dev.wink.test-host",
                    teamIdentifier: signer == "wrong-hash" ? "Y5PE65HELJ" : signer,
                    codeSignatureHash: signer == "wrong-hash" ? "mismatched-hash" : hash)
            }))
        do {
            do {
                try await client.handshake(client: .init(
                    bundleIdentifier: "dev.wink.signer-tests",
                    teamIdentifier: nil,
                    processIdentifier: ProcessInfo.processInfo.processIdentifier))
                Issue.record("Expected handshake refusal")
            } catch let envelope as WinkBridgeErrorEnvelope {
                #expect(envelope.code == (acceptedSigner ? .invalidRequest : .unauthorizedClient))
            }
            #expect(await peer.acceptedConnectionCount == 1)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }
}
