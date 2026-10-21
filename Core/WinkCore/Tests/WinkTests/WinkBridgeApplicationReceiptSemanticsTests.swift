import Foundation
import WinkAutomationKit
import WinkFoundation
import Testing
@testable import WinkBridge
@testable import WinkCore

@Suite(.serialized)
struct WinkBridgeApplicationReceiptSemanticsTests {
    @Test
    func `signed relaunch receipt requires a distinct generation and change-compatible outcome`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wink-relaunch-receipt-binding-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WinkBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let oldIdentity = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 455)
        let newIdentity = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 456)
        let rawRequest = WinkBridgeRequest.relaunchApplicationWithOptions(.init(
            targetIdentifier: "PID:123",
            expectedTargetIdentity: oldIdentity,
            launchRequest: .init(applicationBundleIdentifier: "dev.stub", activates: true)))
        let request = WinkBridgeRequest.projectedAction(.init(request: rawRequest))

        func makeBundle(
            sequence: UInt64,
            identity: ApplicationProcessIdentity,
            outcome: DesktopActionOutcome) async throws -> WinkBridgeOperationReceiptBundle
        {
            let application = ServiceApplicationInfo(
                processIdentifier: identity.processIdentifier,
                processStartIdentity: identity.processStartIdentity,
                bundleIdentifier: "dev.stub",
                name: "StubApp")
            let response = WinkBridgeResponse.projectedAction(.init(
                response: .application(application),
                outcome: outcome.projection))
            let accepted = try await session.acceptedClaim(
                authority: authority,
                sequence: sequence,
                request: request)
            let payload = try OperationReceiptSessionFixture.receiptPayload(
                authority: authority,
                claim: accepted.claim,
                request: request,
                response: response,
                target: .process(identity),
                outcome: outcome.projection)
            let receipt = try await authority.signAndArchive(payload, claim: accepted.claim)
            let bundle = try OperationReceiptSessionFixture.bundle(
                authority: authority,
                sessionAttestation: session.attestation,
                receipt: receipt,
                request: request,
                response: response)
            authority.complete(accepted.claim)
            return bundle
        }

        let changed = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one)
        try await makeBundle(sequence: 0, identity: newIdentity, outcome: changed).validate()

        let unchanged = try await makeBundle(sequence: 1, identity: oldIdentity, outcome: changed)
        #expect(throws: WinkBridgeOperationReceiptError.self) {
            try unchanged.validate()
        }

        let noChange = DesktopActionOutcome.confirmedNoChange(route: .bridge)
        let contradictory = try await makeBundle(sequence: 2, identity: newIdentity, outcome: noChange)
        #expect(throws: WinkBridgeOperationReceiptError.self) {
            try contradictory.validate()
        }
    }
}
