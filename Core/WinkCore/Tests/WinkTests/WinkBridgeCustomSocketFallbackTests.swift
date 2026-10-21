import Foundation
import WinkAutomationKit
import Testing
@testable import WinkBridge
@testable import WinkCore

@Suite(.serialized)
struct WinkBridgeCustomSocketFallbackTests {
    @Test(arguments: [28, 27, 12, 1, 0])
    @MainActor
    func `default custom socket handshake falls back from receiptless cap`(hostMinorVersion: Int) async throws {
        let version = WinkBridgeProtocolVersion(major: 1, minor: hostMinorVersion)
        let root = URL(fileURLWithPath: "/tmp/pb-fallback-\(hostMinorVersion)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("bridge.sock").path
        let server = WinkBridgeServer(
            services: WinkServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: version...version)
        let host = WinkBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 5)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = WinkBridgeClient(socketPath: socketPath, requestTimeoutSec: 5)
        let handshake = try await client.handshake(client: Self.clientIdentity)

        #expect(handshake.negotiatedVersion == version)
        #expect(handshake.operationAttestation == nil)
        #expect(handshake.operationSessionAttestation == nil)
    }

    @Test
    @MainActor
    func `explicit custom socket protocol remains exact instead of falling back`() async throws {
        let hostVersion = WinkBridgeProtocolVersion(major: 1, minor: 27)
        let requestedVersion = WinkBridgeProtocolVersion(major: 1, minor: 28)
        let root = URL(fileURLWithPath: "/tmp/pb-exact-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("bridge.sock").path
        let server = WinkBridgeServer(
            services: WinkServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: hostVersion...hostVersion)
        let host = WinkBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = WinkBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        do {
            _ = try await client.handshake(
                client: Self.clientIdentity,
                protocolVersion: requestedVersion)
            Issue.record("An explicit protocol request unexpectedly negotiated an older version")
        } catch let envelope as WinkBridgeErrorEnvelope {
            #expect(envelope.code == .versionMismatch)
        }
    }

    private static let clientIdentity = WinkBridgeClientIdentity(
        bundleIdentifier: "dev.wink.custom-socket-fallback-tests",
        teamIdentifier: nil,
        processIdentifier: getpid())
}
