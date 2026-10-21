import Foundation
import Testing
@testable import WinkBridge

struct WinkBridgeClientHostTrustTests {
    @Test(arguments: [
        "OpenClaw/bridge.sock",
        "Wink/bridge.sock",
        "Wink/daemon.sock",
        "Wink/daemon-0123456789abcdef.sock",
        "Claude/bridge.sock",
        "clawdbot/bridge.sock",
    ])
    func `default first party trust offers current protocol and modern client capabilities`(
        relativePath: String) async throws
    {
        let probe = HandshakeOfferProbe()
        let client = WinkBridgeClient(socketPath: Self.socketPath(relativePath), encoder: probe)
        #expect(await client.trustedHostTeamIDs == ["Y5PE65HELJ", "FWJYW4S8P8"])

        let offer = try await Self.offer(from: client, probe: probe)
        #expect(offer.protocolVersion == WinkBridgeConstants.protocolVersion)
        #expect(offer.clientCapabilities?.contains(
            WinkBridgeClientCapability.producerBoundSnapshotReferences) == true)
        #expect(offer.clientCapabilities?.contains(
            WinkBridgeClientCapability.targetedClickAccessibilityValueDelivery) == true)
    }

    @Test(arguments: [
        "OpenClaw/other.sock",
        "OpenClaw/bridge.sock.backup",
        "OpenClaw/daemon-0123456789abcdef.sock",
        "OpenClaw/nested/bridge.sock",
        "OpenClaw-copy/bridge.sock",
        "openclaw/bridge.sock",
        "Other/bridge.sock",
    ])
    func `untrusted paths still offer receiptless protocol 1 28`(relativePath: String) async throws {
        let probe = HandshakeOfferProbe()
        let client = WinkBridgeClient(socketPath: Self.socketPath(relativePath), encoder: probe)
        #expect(await client.trustedHostTeamIDs == nil)

        let offer = try await Self.offer(from: client, probe: probe)
        #expect(offer.protocolVersion == .init(major: 1, minor: 28))
        #expect(offer.clientCapabilities == nil)
    }

    @Test(arguments: [nil, [], ["CUSTOM-TEAM"]] as [Set<String>?])
    func `custom socket modern offer still requires explicit nonempty trust`(
        explicitTrust: Set<String>?) async throws
    {
        let probe = HandshakeOfferProbe()
        let client = WinkBridgeClient(
            socketPath: "/tmp/custom-wink.sock",
            encoder: probe,
            trustedHostTeamIDs: explicitTrust)
        let offer = try await Self.offer(from: client, probe: probe)
        let expected = explicitTrust?.isEmpty == false
            ? WinkBridgeConstants.protocolVersion
            : WinkBridgeProtocolVersion(major: 1, minor: 28)
        #expect(offer.protocolVersion == expected)
    }

    @Test
    func `canonical OpenClaw preserves explicit team override and explicit legacy offer`() async throws {
        let probe = HandshakeOfferProbe()
        let client = WinkBridgeClient(
            socketPath: Self.socketPath("OpenClaw/bridge.sock"),
            encoder: probe,
            trustedHostTeamIDs: ["EXPLICIT-TEAM"])
        #expect(await client.trustedHostTeamIDs == ["EXPLICIT-TEAM"])
        let legacy = WinkBridgeProtocolVersion(major: 1, minor: 28)
        let offer = try await Self.offer(from: client, probe: probe, protocolVersion: legacy)
        #expect(offer.protocolVersion == legacy)
        #expect(offer.clientCapabilities == nil)
    }

    private static func socketPath(_ relativePath: String) -> String {
        URL(fileURLWithPath: WinkBridgeConstants.winkSocketPath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relativePath).path
    }

    @Test(arguments: [28, 29])
    func `wire capability field begins with receipt capable negotiation`(minor: Int) async throws {
        let probe = HandshakeOfferProbe()
        let client = WinkBridgeClient(socketPath: Self.socketPath("Wink/bridge.sock"), encoder: probe)
        let offer = try await Self.offer(from: client, probe: probe, protocolVersion: .init(major: 1, minor: minor))
        let data = try JSONEncoder.winkBridgeEncoder().encode(offer)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if minor == 28 {
            #expect(object["clientCapabilities"] == nil)
        } else {
            let capabilities = try #require(object["clientCapabilities"] as? [String])
            #expect(capabilities.contains(WinkBridgeClientCapability.screenCaptureKitOwnershipDiagnostics))
        }
    }

    private static func offer(
        from client: WinkBridgeClient,
        probe: HandshakeOfferProbe,
        protocolVersion: WinkBridgeProtocolVersion = WinkBridgeConstants.protocolVersion)
        async throws -> WinkBridgeHandshake
    {
        do {
            try await client.handshake(
                client: .init(bundleIdentifier: "dev.wink.offer-tests", teamIdentifier: nil, processIdentifier: 42),
                protocolVersion: protocolVersion)
            Issue.record("Expected the probe to stop the handshake before transport")
        } catch HandshakeOfferProbe.Stop.beforeTransport {
            // Capturing an offer proves client policy, not negotiation or receipt-backed execution.
        }
        return try #require(probe.offer)
    }
}

private final class HandshakeOfferProbe: JSONEncoder, @unchecked Sendable {
    enum Stop: Error { case beforeTransport }

    private let lock = NSLock()
    private var capturedOffer: WinkBridgeHandshake?

    var offer: WinkBridgeHandshake? {
        self.lock.withLock { self.capturedOffer }
    }

    override func encode(_ value: some Encodable) throws -> Data {
        if let request = value as? WinkBridgeRequest, case let .handshake(offer) = request {
            self.lock.withLock { self.capturedOffer = offer }
        }
        throw Stop.beforeTransport
    }
}
