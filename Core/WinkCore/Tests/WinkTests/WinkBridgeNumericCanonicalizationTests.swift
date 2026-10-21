import Foundation
import WinkAutomationKit
import WinkFoundation
import Testing
@testable import WinkBridge

@Suite(.serialized)
struct WinkBridgeNumericCanonicalizationTests {
    @Test
    func `UI element double zero has stable canonical bytes`() throws {
        let encoder = JSONEncoder.winkBridgeEncoder()
        let decoder = JSONDecoder.winkBridgeDecoder()

        let encoded = try encoder.encode(UIElementValue.double(-0.0))
        let decoded = try decoder.decode(UIElementValue.self, from: encoded)

        #expect(encoded == Data("0".utf8))
        #expect(decoded == .int(0))
        #expect(try encoder.encode(decoded) == encoded)

        let nonzero = UIElementValue.double(-0.5)
        #expect(try decoder.decode(UIElementValue.self, from: encoder.encode(nonzero)) == nonzero)
    }

    @Test
    func `Bridge JSON double zero has stable canonical bytes recursively`() throws {
        let encoder = JSONEncoder.winkBridgeEncoder()
        let decoder = JSONDecoder.winkBridgeDecoder()
        let value = WinkBridgeJSONValue.object([
            "nested": .array([.double(-0.0), .double(-0.5)]),
        ])

        let encoded = try encoder.encode(value)
        let decoded = try decoder.decode(WinkBridgeJSONValue.self, from: encoded)

        #expect(decoded == .object([
            "nested": .array([.int(0), .double(-0.5)]),
        ]))
        #expect(try encoder.encode(decoded) == encoded)
    }

    @Test
    func `setValue semantic planning follows canonical numeric values without coercing strings`() {
        let negativeZero = WinkBridgeOperationResultSemantics.semanticPlan(for: .setValue(.init(
            target: "T1",
            value: .double(-0.0),
            snapshotId: "snapshot")))
        let positiveZero = WinkBridgeOperationResultSemantics.semanticPlan(for: .setValue(.init(
            target: "T1",
            value: .double(0.0),
            snapshotId: "snapshot")))
        let integerZero = WinkBridgeOperationResultSemantics.semanticPlan(for: .setValue(.init(
            target: "T1",
            value: .int(0),
            snapshotId: "snapshot")))
        let numericString = WinkBridgeOperationResultSemantics.semanticPlan(for: .setValue(.init(
            target: "T1",
            value: .string("-0.0"),
            snapshotId: "snapshot")))

        #expect(negativeZero.typedResponseRule == .setValue(target: "T1", value: .int(0)))
        #expect(positiveZero.typedResponseRule == negativeZero.typedResponseRule)
        #expect(integerZero.typedResponseRule == negativeZero.typedResponseRule)
        #expect(numericString.typedResponseRule == .setValue(target: "T1", value: .string("-0.0")))
    }

    @Test
    @MainActor
    func `signed setValue request canonicalizes negative zero without response loss`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pb-sv-nz-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("bridge.sock").path
        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let services = StubServices()
        services.automationStub.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        services.automationStub.uiAutomationOutcomeTargetIdentity = try DesktopTargetIdentity(
            processIdentity: .init(
                processIdentifier: getpid(),
                processStartIdentity: processStartIdentity))
        let server = WinkBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = WinkBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let result = try await client.setValue(
            target: "T1",
            value: .double(-0.0),
            snapshotId: "snapshot")

        #expect(result.target == "T1")
        #expect(services.automationStub.lastSetValue?.value == .int(0))
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        let decodedRequest = try JSONDecoder.winkBridgeDecoder().decode(
            WinkBridgeRequest.self,
            from: bundle.canonicalRequest)
        #expect(try WinkBridgeOperationReceiptCoding.canonicalData(decodedRequest) == bundle.canonicalRequest)
    }

    @Test
    @MainActor
    func `signed browser response canonicalizes negative zero without response loss`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pb-br-nz-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("bridge.sock").path
        let services = StubServices()
        services.browserConnectionReceipt = Self.browserReceipt
        services.browserResponseContent = [.object(["number": .double(-0.0)])]
        let server = WinkBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = WinkBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let result = try await client.browserExecuteResult(.init(
            toolName: "fixture",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: Self.browserReceipt))

        #expect(result.payload.content == [.object(["number": .int(0)])])
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        let decodedResponse = try JSONDecoder.winkBridgeDecoder().decode(
            WinkBridgeResponse.self,
            from: bundle.canonicalResponse)
        #expect(try WinkBridgeOperationReceiptCoding.canonicalData(decodedResponse) == bundle.canonicalResponse)
    }

    private static let clientIdentity = WinkBridgeClientIdentity(
        bundleIdentifier: "dev.wink.numeric-canonicalization-tests",
        teamIdentifier: nil,
        processIdentifier: getpid())
    private static let browserReceipt = WinkBridgeBrowserConnectionReceipt(
        channel: "stable",
        browserURL: "http://127.0.0.1:9222",
        webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/fixture",
        devToolsBrowserID: "fixture",
        browserVersion: "Chrome/151.0",
        protocolVersion: "1.3")
}
