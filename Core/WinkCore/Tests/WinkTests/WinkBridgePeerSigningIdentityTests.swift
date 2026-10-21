import Darwin
import Foundation
import WinkAutomationKit
import Security
import Testing
@testable import WinkBridge

struct WinkBridgePeerSigningIdentityTests {
    @Test
    func `anchored requirement construction rejects metadata grammar injection`() {
        #expect(WinkBridgeCodeSignatureIdentity.appleAnchoredRequirement(
            identifier: #"boo.wink\" or anchor apple"#,
            teamIdentifier: "FWJYW4S8P8") == nil)
        #expect(WinkBridgeCodeSignatureIdentity.appleAnchoredRequirement(
            identifier: "boo.wink.wink",
            teamIdentifier: #"FWJYW4S8P8\" or true"#) == nil)
        #expect(WinkBridgeCodeSignatureIdentity.appleAnchoredRequirement(
            identifier: "boo.wink.wink",
            teamIdentifier: "FWJYW4S8P8") != nil)
    }

    @Test
    func `same UID peer retains a kernel CDHash when certificate trust is unavailable`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }

        let peer = try #require(WinkBridgeHost.peerInfoIfAllowed(
            fd: sockets.reader,
            allowedTeamIDs: []))

        #expect(peer.processIdentifier == getpid())
        #expect(peer.codeSignatureHash?.count == 40)
        #expect(peer.userIdentifier == geteuid())
    }

    @Test
    func `same UID legacy peer retains kernel identity without signing metadata`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }

        let peer = try #require(WinkBridgeHost.peerInfoIfAllowed(
            fd: sockets.reader,
            allowedTeamIDs: [],
            signingIdentityProvider: { _ in nil }))

        #expect(peer.processIdentifier == getpid())
        #expect(peer.auditTokenProcessIdentifierVersion != nil)
        #expect(peer.codeSignatureHash?.count == 40)
        #expect(peer.userIdentifier == geteuid())
    }

    @Test
    func `team restricted peer still requires signing metadata`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }

        let peer = WinkBridgeHost.peerInfoIfAllowed(
            fd: sockets.reader,
            allowedTeamIDs: ["FWJYW4S8P8"],
            signingIdentityProvider: { _ in nil })

        #expect(peer == nil)
    }

    @Test
    func `team metadata without an exact trusted CDHash never authorizes`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }

        let hash = Data((1...20).map(UInt8.init))
        let liveIdentity = try Self.liveIdentity(fd: sockets.reader, hash: hash)
        let peer = WinkBridgeHost.peerInfoIfAllowed(
            liveIdentity: liveIdentity,
            allowedTeamIDs: ["FWJYW4S8P8"],
            signingIdentityProvider: { _ in
                .init(
                    bundleIdentifier: "boo.wink.wink",
                    teamIdentifier: "FWJYW4S8P8",
                    codeSignatureHash: nil)
            })

        #expect(peer == nil)
    }

    @Test
    func `nil CDHash debug override exposes no unanchored team or bundle claims`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }

        let liveIdentity = try Self.liveIdentity(fd: sockets.reader, hash: nil)
        let claimedIdentity: (WinkBridgePeerAuditIdentity) -> WinkBridgeHost.PeerSigningIdentity? = { _ in
            .init(
                bundleIdentifier: "boo.wink.unanchored",
                teamIdentifier: "FWJYW4S8P8",
                codeSignatureHash: String(repeating: "a", count: 40))
        }
        #expect(WinkBridgeHost.peerInfoIfAllowed(
            liveIdentity: liveIdentity,
            allowedTeamIDs: ["FWJYW4S8P8"],
            signingIdentityProvider: claimedIdentity,
            allowUnsignedSocketClients: false) == nil)

        let peer = try #require(WinkBridgeHost.peerInfoIfAllowed(
            liveIdentity: liveIdentity,
            allowedTeamIDs: ["FWJYW4S8P8"],
            signingIdentityProvider: claimedIdentity,
            allowUnsignedSocketClients: true))
        #expect(peer.processIdentifier == getpid())
        #expect(peer.codeSignatureHash == nil)
        #expect(peer.teamIdentifier == nil)
        #expect(peer.bundleIdentifier == nil)
    }

    @Test
    func `team restricted peer rejects replaced executable metadata with a different live CDHash`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }

        let liveHash = Data((1...20).map(UInt8.init))
        let replacementHash = Data(repeating: 0xA5, count: 20)
        let liveIdentity = try Self.liveIdentity(fd: sockets.reader, hash: liveHash)
        var observedTokens: [Data] = []
        var staticLookupCount = 0
        let peer = WinkBridgeHost.peerInfoIfAllowed(
            liveIdentity: liveIdentity,
            allowedTeamIDs: ["FWJYW4S8P8"],
            signingIdentityProvider: { identity in
                WinkBridgeHost.signingIdentity(
                    auditIdentity: identity,
                    systemCall: { processIdentifier, operation, address, byteCount, auditToken in
                        #expect(processIdentifier == identity.processIdentifier)
                        #expect(operation == 5)
                        #expect(byteCount == 20)
                        if let auditToken {
                            let observedToken = Data(
                                bytes: auditToken,
                                count: MemoryLayout<audit_token_t>.size)
                            #expect(observedToken == identity.tokenData)
                            observedTokens.append(observedToken)
                        }
                        return Self.copy(liveHash, to: address, byteCount: byteCount)
                    },
                    staticSigningInformationProvider: { requestedIdentity in
                        staticLookupCount += 1
                        #expect(requestedIdentity.tokenData == identity.tokenData)
                        return [
                            kSecCodeInfoIdentifier as String: "boo.wink.replaced",
                            kSecCodeInfoTeamIdentifier as String: "FWJYW4S8P8",
                            kSecCodeInfoUnique as String: replacementHash,
                        ]
                    },
                    anchoredSignatureValidationProvider: { _ in
                        Issue.record("Validation must not run after the static CDHash already mismatched")
                        return nil
                    })
            })

        #expect(peer == nil)
        #expect(staticLookupCount == 1)
        #expect(observedTokens.count == 2)
    }

    @Test
    func `team restricted peer fails closed when audit token CDHash lookup fails`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }

        var staticLookupCount = 0
        let hash = Data(repeating: 0xA5, count: 20)
        let liveIdentity = try Self.liveIdentity(fd: sockets.reader, hash: hash)
        let peer = WinkBridgeHost.peerInfoIfAllowed(
            liveIdentity: liveIdentity,
            allowedTeamIDs: ["FWJYW4S8P8"],
            signingIdentityProvider: { identity in
                WinkBridgeHost.signingIdentity(
                    auditIdentity: identity,
                    systemCall: { _, _, _, _, _ in -1 },
                    staticSigningInformationProvider: { _ in
                        staticLookupCount += 1
                        return [
                            kSecCodeInfoIdentifier as String: "boo.wink.wink",
                            kSecCodeInfoTeamIdentifier as String: "FWJYW4S8P8",
                            kSecCodeInfoUnique as String: hash,
                        ]
                    },
                    anchoredSignatureValidationProvider: { _ in
                        Issue.record("Validation must not run without a live CDHash")
                        return nil
                    })
            })

        #expect(peer == nil)
        #expect(staticLookupCount == 0)
    }

    @Test
    func `team restricted peer accepts exact independently validated certificate identity`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }

        let hash = Data((1...20).map(UInt8.init))
        let liveIdentity = try Self.liveIdentity(fd: sockets.reader, hash: hash)
        let peer = WinkBridgeHost.peerInfoIfAllowed(
            liveIdentity: liveIdentity,
            allowedTeamIDs: ["FWJYW4S8P8"],
            signingIdentityProvider: { identity in
                WinkBridgeHost.signingIdentity(
                    auditIdentity: identity,
                    systemCall: Self.hashSystemCall(hash),
                    staticSigningInformationProvider: { _ in
                        Self.signingInformation(hash: hash)
                    },
                    anchoredSignatureValidationProvider: { _ in
                        .init(
                            identifier: "boo.wink.wink",
                            teamIdentifier: "FWJYW4S8P8",
                            codeDirectoryHash: hash)
                    })
            })

        #expect(peer?.bundleIdentifier == "boo.wink.wink")
        #expect(peer?.teamIdentifier == "FWJYW4S8P8")
        #expect(peer?.codeSignatureHash == hash.map { String(format: "%02x", $0) }.joined())
    }

    @Test(arguments: [
        WinkBridgeCodeSignatureIdentity.ValidatedSigningIdentity(
            identifier: "boo.wink.wink",
            teamIdentifier: "OTHERTEAM1",
            codeDirectoryHash: Data((1...20).map(UInt8.init))),
        WinkBridgeCodeSignatureIdentity.ValidatedSigningIdentity(
            identifier: "boo.wink.impostor",
            teamIdentifier: "FWJYW4S8P8",
            codeDirectoryHash: Data((1...20).map(UInt8.init))),
        WinkBridgeCodeSignatureIdentity.ValidatedSigningIdentity(
            identifier: "boo.wink.wink",
            teamIdentifier: "FWJYW4S8P8",
            codeDirectoryHash: Data(repeating: 0xA5, count: 20)),
    ])
    func `team restricted peer rejects mismatched validated certificate metadata`(
        validatedIdentity: WinkBridgeCodeSignatureIdentity.ValidatedSigningIdentity) throws
    {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }

        let hash = Data((1...20).map(UInt8.init))
        let liveIdentity = try Self.liveIdentity(fd: sockets.reader, hash: hash)
        let peer = WinkBridgeHost.peerInfoIfAllowed(
            liveIdentity: liveIdentity,
            allowedTeamIDs: ["FWJYW4S8P8"],
            signingIdentityProvider: { identity in
                WinkBridgeHost.signingIdentity(
                    auditIdentity: identity,
                    systemCall: Self.hashSystemCall(hash),
                    staticSigningInformationProvider: { _ in Self.signingInformation(hash: hash) },
                    anchoredSignatureValidationProvider: { _ in validatedIdentity })
            })

        #expect(peer == nil)
    }

    @Test
    func `team restricted peer rejects ad hoc untrusted or failed signature validation`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }

        let hash = Data((1...20).map(UInt8.init))
        let liveIdentity = try Self.liveIdentity(fd: sockets.reader, hash: hash)
        let peer = WinkBridgeHost.peerInfoIfAllowed(
            liveIdentity: liveIdentity,
            allowedTeamIDs: ["FWJYW4S8P8"],
            signingIdentityProvider: { identity in
                WinkBridgeHost.signingIdentity(
                    auditIdentity: identity,
                    systemCall: Self.hashSystemCall(hash),
                    staticSigningInformationProvider: { _ in Self.signingInformation(hash: hash) },
                    anchoredSignatureValidationProvider: { _ in nil })
            })

        #expect(peer == nil)
    }

    @Test
    func `single signing information lookup supplies bundle and team identity`() {
        var lookupCount = 0
        let identity = WinkBridgeHost.signingIdentity(pid: getpid()) { requestedPID in
            lookupCount += 1
            #expect(requestedPID == getpid())
            return [
                kSecCodeInfoIdentifier as String: "boo.wink.wink",
                kSecCodeInfoTeamIdentifier as String: "FWJYW4S8P8",
            ]
        }

        #expect(lookupCount == 1)
        #expect(identity?.bundleIdentifier == "boo.wink.wink")
        #expect(identity?.teamIdentifier == "FWJYW4S8P8")
    }

    @Test
    func `signing identity preserves application identifier team fallback`() {
        let identity = WinkBridgeHost.signingIdentity(pid: getpid()) { _ in
            [
                kSecCodeInfoIdentifier as String: "boo.wink.wink",
                kSecCodeInfoEntitlementsDict as String: [
                    "application-identifier": "FWJYW4S8P8.boo.wink.wink",
                ],
            ]
        }

        #expect(identity?.bundleIdentifier == "boo.wink.wink")
        #expect(identity?.teamIdentifier == "FWJYW4S8P8")
    }

    private static func socketPair() throws -> (reader: Int32, writer: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptors[0], descriptors[1])
    }

    private static func copy(_ data: Data, to address: UnsafeMutableRawPointer?, byteCount: Int) -> Int32 {
        guard data.count == byteCount, let address else { return -1 }
        data.withUnsafeBytes { buffer in
            address.copyMemory(from: buffer.baseAddress!, byteCount: byteCount)
        }
        return 0
    }

    private static func hashSystemCall(
        _ hash: Data) -> WinkBridgeCodeSignatureIdentity.AuditTokenCDHashSystemCall
    {
        { _, operation, address, byteCount, _ in
            #expect(operation == 5)
            #expect(byteCount == 20)
            return Self.copy(hash, to: address, byteCount: byteCount)
        }
    }

    private static func signingInformation(hash: Data) -> [String: Any] {
        [
            kSecCodeInfoIdentifier as String: "boo.wink.wink",
            kSecCodeInfoTeamIdentifier as String: "FWJYW4S8P8",
            kSecCodeInfoUnique as String: hash,
        ]
    }

    private static func liveIdentity(fd: Int32, hash: Data?) throws -> WinkBridgeLivePeerIdentity {
        let auditIdentity = try WinkBridgeSocketIO.peerAuditIdentity(fd: fd)
        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(
            auditIdentity.processIdentifier))
        return WinkBridgeLivePeerIdentity(
            auditIdentity: auditIdentity,
            processStartIdentity: processStartIdentity,
            codeSignatureHash: hash?.map { String(format: "%02x", $0) }.joined())
    }
}
