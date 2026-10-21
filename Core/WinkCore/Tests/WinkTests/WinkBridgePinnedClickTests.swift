import CoreGraphics
import Foundation
import WinkAutomationKit
import WinkBridge
import Testing

struct WinkBridgePinnedClickTests {
    private let exactIdentity = WindowMutationIdentity(
        windowID: 42,
        ownerProcessIdentifier: 9001,
        ownerProcessStartIdentity: 1)
    private let exactBounds = CGRect(x: 0, y: 0, width: 100, height: 100)

    private func decode(_ data: Data) throws -> WinkBridgeResponse {
        try JSONDecoder.winkBridgeDecoder().decode(WinkBridgeResponse.self, from: data)
    }

    @Test
    @MainActor
    func `automation targeted click forwards process-generation receipt`() async throws {
        let services = StubServices()
        let server = WinkBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let identity = ApplicationProcessIdentity(processIdentifier: 9001, processStartIdentity: 71)
        let request = WinkBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: identity.processIdentifier,
            expectedProcessIdentity: identity))

        let response = try await self.decode(server.decodeAndHandle(
            JSONEncoder.winkBridgeEncoder().encode(request),
            peer: nil))

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }
        #expect(services.automationStub.lastProcessTargetedClick?.expectedProcessIdentity == identity)
    }

    @Test
    @MainActor
    func `targeted click rejects mismatched or duplicate process receipts before dispatch`() async throws {
        let services = StubServices()
        let server = WinkBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let mismatch = WinkBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001,
            expectedProcessIdentity: .init(processIdentifier: 9002, processStartIdentity: 71)))
        let duplicate = WinkBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001,
            expectedProcessIdentity: .init(processIdentifier: 9001, processStartIdentity: 71),
            targetWindowID: 42,
            expectedWindowIdentity: self.exactIdentity,
            expectedWindowBounds: self.exactBounds))

        for request in [mismatch, duplicate] {
            let response = try await self.decode(server.decodeAndHandle(
                JSONEncoder.winkBridgeEncoder().encode(request),
                peer: nil))
            guard case let .error(error) = response else {
                Issue.record("Expected invalid request, got \(response)")
                continue
            }
            #expect(error.code == .invalidRequest)
        }
        #expect(services.automationStub.lastProcessTargetedClick?.targetProcessIdentifier == nil)
    }

    @Test
    func `legacy targeted click payload decodes without process receipt`() throws {
        let data = try JSONEncoder.winkBridgeEncoder().encode(
            WinkBridgeTargetedClickRequest(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: 9001))

        let payload = try JSONDecoder.winkBridgeDecoder().decode(
            WinkBridgeTargetedClickRequest.self,
            from: data)

        #expect(payload.expectedProcessIdentity == nil)
    }
}
