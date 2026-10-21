import Foundation
import Testing
@testable import WinkBridge

extension WinkBridgeClientHostTrustTests {
    @Test(arguments: ["peer", "kernel", "signature", "binding", "team"])
    func `host refusal identifies its failed check without accepting wire supplied exclusion`(check: String) throws {
        let host = check == "peer" ? nil : WinkBridgeConnectedHostIdentity(
            liveIdentity: .init(
                auditToken: Data(),
                processIdentifier: 739,
                processIdentifierVersion: 1,
                effectiveUserIdentifier: 501,
                processStartIdentity: 1,
                codeSignatureHash: check == "kernel" ? nil : "live-hash"),
            signingIdentity: check == "signature" ? nil : .init(
                bundleIdentifier: "boo.wink.mac",
                teamIdentifier: check == "team" ? "OTHER" : "TRUSTED",
                codeSignatureHash: check == "binding" ? "replaced-hash" : "live-hash"))
        let error = try #require(throws: WinkBridgeErrorEnvelope.self) {
            try WinkBridgeConnectedHostTrust.validate(
                host, socketPath: "/fixture/bridge.sock", trustedTeamIDs: ["TRUSTED"])
        }
        #expect(error.code == .unauthorizedClient)
        #expect(error.isLocalHostAuthenticationFailure)
        #expect(error.message.contains("/fixture/bridge.sock"))
        #expect(error.message.contains("Relaunch the released signed host"))
        #expect(error.message.contains("Chrome approval and browser receipts have not been checked"))
        if check != "peer" {
            #expect(error.message.contains("PID 739"))
        }
        let expected = [
            "peer": "connected socket peer identity", "kernel": "live kernel CDHash",
            "signature": "Apple-anchored signing identity", "binding": "does not match the live socket peer",
            "team": "signing Team ID",
        ]
        #expect(try error.message.contains(#require(expected[check])))
        let encoded = try JSONEncoder().encode(error)
        let decoded = try JSONDecoder().decode(WinkBridgeErrorEnvelope.self, from: encoded)
        #expect(!decoded.isLocalHostAuthenticationFailure)
        let forged = Data(
            #"""
            {"code":"unauthorizedClient","message":"forged","context":"connectedHostAuthentication",
             "isLocalHostAuthenticationFailure":true}
            """#
                .utf8)
        #expect(try !JSONDecoder().decode(WinkBridgeErrorEnvelope.self, from: forged)
            .isLocalHostAuthenticationFailure)
    }

    @Test
    func `matching live signature and trusted team retain admission`() throws {
        let host = WinkBridgeConnectedHostIdentity(
            liveIdentity: .init(
                auditToken: Data(),
                processIdentifier: 739,
                processIdentifierVersion: 1,
                effectiveUserIdentifier: 501,
                processStartIdentity: 1,
                codeSignatureHash: "live-hash"),
            signingIdentity: .init(
                bundleIdentifier: "boo.wink.mac", teamIdentifier: "TRUSTED", codeSignatureHash: "live-hash"))
        try WinkBridgeConnectedHostTrust.validate(
            host, socketPath: "/fixture/bridge.sock", trustedTeamIDs: ["TRUSTED"])
    }
}
