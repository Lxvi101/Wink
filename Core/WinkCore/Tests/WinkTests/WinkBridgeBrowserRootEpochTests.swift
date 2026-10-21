import Darwin
import Foundation
import WinkBridgeTestSupport
import Testing
@testable import WinkBridge

@MainActor
struct WinkBridgeBrowserRootEpochTests {
    @Test(arguments: ["list_pages", "new_page"])
    func `root status epoch is not copied into scoped request authority`(toolName: String) async throws {
        let version = WinkBridgeProtocolVersion(major: 1, minor: 28)
        let receipt = WinkBridgeBrowserClientTests.browserReceipt
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: version,
                supportedOperations: [.browserStatus, .browserExecute])),
            .browserStatus(.init(
                isConnected: true,
                toolCount: 30,
                detectedBrowsers: [],
                connectionReceipt: receipt,
                providerSessionEpoch: UUID())),
            .browserToolResponse(.init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: receipt,
                completedCallCount: 1,
                dispatchedCallCount: 1)),
        ])
        let client = WinkBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.wink.root-epoch",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: version)
        _ = try await client.browserExecute(.init(toolName: toolName, arguments: [:], channel: "stable"))
        await peer.waitUntilFinished()
        let requests = await peer.requests
        #expect(requests.count == 3)
        let data = try #require(requests.last)
        let request = try JSONDecoder.winkBridgeDecoder().decode(WinkBridgeRequest.self, from: data)
        guard case let .browserExecute(execute) = request else {
            Issue.record("Expected browser execution")
            return
        }
        #expect(execute.expectedConnectionReceipt == receipt)
        #expect(execute.connectionPolicy == .requireExistingLiveReceipt)
        #expect(execute.sessionID == nil)
        #expect(execute.expectedProviderSessionEpoch == nil)
        try WinkBridgeServer.validateBrowserSessionRequest(request)
    }
}
