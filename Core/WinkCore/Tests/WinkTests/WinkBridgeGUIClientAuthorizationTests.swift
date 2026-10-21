import Darwin
import Foundation
import Testing
@testable import WinkBridge
@testable import WinkCore

@MainActor
struct WinkBridgeGUIClientAuthorizationTests {
    @Test(arguments: [
        "boo.wink.wink",
        "boo.wink.mac",
        "boo.wink.wink-certification-controller",
    ], ["Y5PE65HELJ", "FWJYW4S8P8"])
    func `accepts first party clients`(bundle: String, team: String) throws {
        try Self.server().validatePeerAuthorization(Self.peer(bundle: bundle, team: team))
    }

    @Test(arguments: [
        "org.openclaw.unrelated",
        "boo.wink.wink-certification-controller.extra",
        "boo.wink.background-computer-use-probe",
    ])
    func `rejects unlisted bundles`(bundle: String) {
        self.expectRefusal(Self.peer(bundle: bundle))
    }

    @Test(arguments: ["UNTRUSTED1", nil] as [String?])
    func `rejects untrusted or missing team`(team: String?) {
        self.expectRefusal(Self.peer(team: team))
    }

    @Test
    func `rejects missing peer or bundle and wrong user`() {
        self.expectRefusal(nil)
        self.expectRefusal(Self.peer(bundle: nil))
        self.expectRefusal(Self.peer(uid: getuid() + 1))
    }

    @Test
    func `rejects forged controller handshake from unlisted peer`() async throws {
        let request = WinkBridgeRequest.handshake(.init(
            protocolVersion: WinkBridgeConstants.protocolVersion,
            client: .init(
                bundleIdentifier: WinkBridgeConstants.certificationControllerBundleIdentifier,
                teamIdentifier: "FWJYW4S8P8",
                processIdentifier: getpid(),
                hostname: nil),
            requestedHostKind: .gui))
        let response = try await Self.server().decodeAndHandle(
            JSONEncoder.winkBridgeEncoder().encode(request),
            peer: Self.peer(bundle: "org.openclaw.unrelated"))
        guard case let .error(error) = try JSONDecoder.winkBridgeDecoder().decode(
            WinkBridgeResponse.self,
            from: response)
        else {
            Issue.record("An unlisted peer must not claim the controller identity in its handshake")
            return
        }
        #expect(error.code == .unauthorizedClient)
    }

    private func expectRefusal(_ peer: WinkBridgePeer?) {
        do {
            try Self.server().validatePeerAuthorization(peer)
            Issue.record("Expected GUI client authorization refusal")
        } catch let error as WinkBridgeErrorEnvelope {
            #expect(error.code == .unauthorizedClient)
        } catch {
            Issue.record("Unexpected authorization error: \(error)")
        }
    }

    private static func server() -> WinkBridgeServer {
        WinkBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: WinkBridgeConstants.trustedReleaseTeamIDs,
            allowlistedBundles: WinkBridgeConstants.guiClientBundleIdentifiers)
    }

    private static func peer(
        bundle: String? = "boo.wink.wink-certification-controller",
        team: String? = "FWJYW4S8P8",
        uid: uid_t = getuid()) -> WinkBridgePeer
    {
        WinkBridgePeer(
            processIdentifier: getpid(),
            userIdentifier: uid,
            bundleIdentifier: bundle,
            teamIdentifier: team)
    }
}
