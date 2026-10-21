import Darwin
import Foundation
import WinkAutomationKit
import WinkBridgeTestSupport
import WinkCore
import Testing
@testable import WinkBridge

struct WinkBridgeHostIdentityTests {
    private struct LegacyHandshakeResponse: Codable {
        let negotiatedVersion: WinkBridgeProtocolVersion
        let hostKind: WinkBridgeHostKind
        let build: String?
        let supportedOperations: [WinkBridgeOperation]
        let permissionTags: [String: [WinkBridgePermissionKind]]?
    }

    @Test
    @MainActor
    func `current host identity comes from the serving process`() {
        let identity = WinkBridgeHostIdentity.current()

        #expect(identity.processIdentifier == getpid())
        #expect(identity.processStartIdentity == SystemIdentityResolver.processStartIdentity(getpid()))
        #expect(identity.processStartIdentityDecimal == identity.processStartIdentity.map(String.init))
    }

    @Test
    func `host identity preserves a lossless decimal process generation`() throws {
        let generation: UInt64 = 9_007_199_254_740_993
        let identity = WinkBridgeHostIdentity(
            processIdentifier: 4242,
            processStartIdentity: generation,
            bundleIdentifier: "boo.wink.mac",
            bundleShortVersion: "4.0.0",
            bundleVersion: "400",
            codeSignatureHash: "abcdef",
            sourceCommit: "0123456789abcdef0123456789abcdef01234567")

        let data = try JSONEncoder.winkBridgeEncoder().encode(identity)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["processStartIdentityDecimal"] as? String == String(generation))
        #expect(object["sourceCommit"] as? String == "0123456789abcdef0123456789abcdef01234567")
        #expect(try JSONDecoder.winkBridgeDecoder().decode(
            WinkBridgeHostIdentity.self,
            from: data).processStartIdentityDecimal == String(generation))
    }

    @Test
    func `new clients decode older host identity without decimal generation`() throws {
        let data = Data(#"""
        {
            "processIdentifier":4242,
            "processStartIdentity":9876543,
            "bundleIdentifier":"boo.wink.mac",
            "bundleShortVersion":"4.0.0",
            "bundleVersion":"400",
            "codeSignatureHash":"abcdef"
        }
        """#.utf8)

        let identity = try JSONDecoder.winkBridgeDecoder().decode(
            WinkBridgeHostIdentity.self,
            from: data)
        #expect(identity.processStartIdentity == 9_876_543)
        #expect(identity.processStartIdentityDecimal == nil)
        #expect(identity.sourceCommit == nil)
    }

    @Test
    @MainActor
    func `missing generation and signature evidence remain unknown`() {
        let server = WinkBridgeServer(
            services: WinkServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            hostIdentity: .init(
                processIdentifier: 4242,
                processStartIdentity: nil,
                bundleIdentifier: "boo.wink.mac",
                bundleShortVersion: "4.0.0",
                bundleVersion: "400",
                codeSignatureHash: nil))

        #expect(!server.hostCapabilities.contains(WinkBridgeHostCapability.hostGenerationIdentity))
        #expect(!server.hostCapabilities.contains(WinkBridgeHostCapability.codeSignatureBuildIdentity))
    }

    @Test
    func `handshake advertises injected host generation build and launch capabilities`() async throws {
        let hostIdentity = WinkBridgeHostIdentity(
            processIdentifier: 4242,
            processStartIdentity: 9_876_543,
            bundleIdentifier: "boo.wink.mac",
            bundleShortVersion: "4.0.0",
            bundleVersion: "400",
            codeSignatureHash: "abcdef",
            sourceCommit: "0123456789abcdef0123456789abcdef01234567")
        let server = await MainActor.run {
            WinkBridgeServer(
                services: WinkServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                hostIdentity: hostIdentity,
                hostCapabilities: [WinkBridgeHostCapability.backgroundBridgeHost])
        }
        let request = WinkBridgeRequest.handshake(.init(
            protocolVersion: WinkBridgeConstants.protocolVersion,
            client: .init(
                bundleIdentifier: "dev.peeka.cli",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            requestedHostKind: .gui))

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.winkBridgeEncoder().encode(request),
            peer: nil)
        let response = try JSONDecoder.winkBridgeDecoder().decode(WinkBridgeResponse.self, from: responseData)
        guard case let .handshake(handshake) = response else {
            Issue.record("Expected handshake response, got \(response)")
            return
        }

        #expect(handshake.hostIdentity == hostIdentity)
        let expectedCapabilities: Set<String> = [
            WinkBridgeHostCapability.backgroundBridgeHost,
            WinkBridgeHostCapability.codeSignatureBuildIdentity,
            WinkBridgeHostCapability.desktopActionOutcomeProjection,
            WinkBridgeHostCapability.desktopObservationCaptureEngine,
            WinkBridgeHostCapability.desktopObservationOCR,
            WinkBridgeHostCapability.hostGenerationIdentity,
            WinkBridgeHostCapability.processGenerationPinnedApplicationActivation,
            WinkBridgeHostCapability.processGenerationPinnedApplicationHide,
            WinkBridgeHostCapability.safeBackgroundApplicationLaunchNoOp,
            WinkBridgeHostCapability.screenCaptureKitProcessOwnership,
        ]
        #expect(expectedCapabilities.isSubset(of: Set(handshake.hostCapabilities ?? [])))
    }

    @Test
    @MainActor
    func `host advertises desktop observation extensions only when desktop observation is allowed`() {
        let observationServer = WinkBridgeServer(
            services: WinkServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            hostIdentity: nil)
        let captureOnlyServer = WinkBridgeServer(
            services: WinkServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.captureScreen],
            hostIdentity: nil)
        let unverifiedObservationServer = WinkBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            hostIdentity: nil)

        #expect(observationServer.hostCapabilities.contains(WinkBridgeHostCapability.desktopObservationOCR))
        #expect(observationServer.hostCapabilities.contains(
            WinkBridgeHostCapability.desktopObservationFreshAccessibilityTree))
        #expect(!captureOnlyServer.hostCapabilities.contains(
            WinkBridgeHostCapability.desktopObservationFreshAccessibilityTree))
        #expect(observationServer.hostCapabilities.contains(
            WinkBridgeHostCapability.desktopObservationCaptureEngine))
        #expect(!captureOnlyServer.hostCapabilities.contains(WinkBridgeHostCapability.desktopObservationOCR))
        #expect(!captureOnlyServer.hostCapabilities.contains(
            WinkBridgeHostCapability.desktopObservationCaptureEngine))
        #expect(!unverifiedObservationServer.hostCapabilities.contains(
            WinkBridgeHostCapability.desktopObservationCaptureEngine))
    }

    @Test
    func `new clients decode legacy handshakes without host identity`() throws {
        let data = Data(#"""
        {
            "negotiatedVersion":{"major":1,"minor":0},
            "hostKind":"gui",
            "build":"3.9.6 (396)",
            "supportedOperations":[],
            "permissionTags":{}
        }
        """#.utf8)

        let handshake = try JSONDecoder.winkBridgeDecoder().decode(
            WinkBridgeHandshakeResponse.self,
            from: data)

        #expect(handshake.hostIdentity == nil)
        #expect(handshake.hostCapabilities == nil)
    }

    @Test
    func `legacy clients ignore additive host handshake fields`() throws {
        let response = BridgeTestFixtures.handshake(
            negotiatedVersion: WinkBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: "4.0.0 (400)",
            supportedOperations: [],
            hostIdentity: .init(
                processIdentifier: 4242,
                processStartIdentity: 9_876_543,
                bundleIdentifier: "boo.wink.mac",
                bundleShortVersion: "4.0.0",
                bundleVersion: "400",
                codeSignatureHash: "abcdef"),
            hostCapabilities: [WinkBridgeHostCapability.backgroundBridgeHost])

        let data = try JSONEncoder.winkBridgeEncoder().encode(response)
        let legacy = try JSONDecoder.winkBridgeDecoder().decode(LegacyHandshakeResponse.self, from: data)

        #expect(legacy.negotiatedVersion == response.negotiatedVersion)
        #expect(legacy.hostKind == .gui)
        #expect(legacy.build == response.build)
        #expect(legacy.supportedOperations.isEmpty)
    }
}
