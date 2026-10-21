import Foundation
import WinkCore
import Testing
@testable import WinkBridge

struct WinkBridgeAppleScriptCompatibilityTests {
    private func decode(_ data: Data) throws -> WinkBridgeResponse {
        try JSONDecoder.winkBridgeDecoder().decode(WinkBridgeResponse.self, from: data)
    }

    @Test
    func `Current handshake disables legacy AppleScript capability and permission`() async throws {
        let server = await MainActor.run {
            WinkBridgeServer(
                services: WinkServices(),
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [.permissionsStatus, ._appleScriptProbe],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: true,
                        accessibility: true,
                        appleScript: true,
                        postEvent: true)
                })
        }
        let identity = WinkBridgeClientIdentity(
            bundleIdentifier: "dev.wink.tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil)
        let request = WinkBridgeRequest.handshake(.init(
            protocolVersion: WinkBridgeConstants.protocolVersion,
            client: identity,
            requestedHostKind: nil))
        let response = try await self.decode(server.decodeAndHandle(
            JSONEncoder.winkBridgeEncoder().encode(request),
            peer: nil))

        guard case let .handshake(handshake) = response else {
            Issue.record("Expected handshake response, got \(response)")
            return
        }
        #expect(!handshake.supportedOperations.contains(._appleScriptProbe))
        #expect(handshake.enabledOperations?.contains(._appleScriptProbe) != true)
        #expect(handshake.permissions?.appleScript == false)
        #expect(handshake.permissionTags[WinkBridgeOperation._appleScriptProbe.rawValue] == nil)
        #expect(!handshake.permissionTags.values.flatMap(\.self).contains(.appleScript))

        let permissionsResponse = try await self.decode(server.decodeAndHandle(
            JSONEncoder.winkBridgeEncoder().encode(WinkBridgeRequest.permissionsStatus),
            peer: nil))
        guard case let .permissionsStatus(permissions) = permissionsResponse else {
            Issue.record("Expected permissions response, got \(permissionsResponse)")
            return
        }
        #expect(permissions.appleScript == false)
    }

    @Test
    func `Legacy AppleScript probe decodes but current host refuses it without execution`() async throws {
        let server = await MainActor.run {
            WinkBridgeServer(
                services: WinkServices(),
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [._appleScriptProbe])
        }
        let requestData = Data(#"{"appleScriptProbe":{}}"#.utf8)
        let response = try await self.decode(server.decodeAndHandle(requestData, peer: nil))

        guard case let .error(envelope) = response else {
            Issue.record("Expected a structured unsupported-operation response, got \(response)")
            return
        }
        #expect(envelope.code == .operationNotSupported)
    }

    /// Intentionally exercises the deprecated v4.2.2 client contract before transport.
    @Test
    @available(*, deprecated)
    func `Legacy client probe API refuses before transport`() async {
        let client = WinkBridgeClient(
            socketPath: "/tmp/wink-legacy-probe-\(UUID().uuidString).sock")

        do {
            try await client.appleScriptProbe()
            Issue.record("Expected the legacy client API to refuse locally")
        } catch let envelope as WinkBridgeErrorEnvelope {
            #expect(envelope.code == .operationNotSupported)
        } catch {
            Issue.record("Expected a structured unsupported-operation error, got \(error)")
        }
    }
}
