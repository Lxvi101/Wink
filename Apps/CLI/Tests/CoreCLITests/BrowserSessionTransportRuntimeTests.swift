import WinkBridge
import Testing
@testable import WinkCLI
@testable import WinkCore

@Suite(.tags(.safe))
@MainActor
struct BrowserSessionTransportRuntimeTests {
    @Test(arguments: [WinkBridgeHostKind.onDemand, .gui])
    func `runtime injects browser session transport only for exact negotiated capability`(
        hostKind: WinkBridgeHostKind
    ) throws {
        let client = WinkBridgeClient(
            socketPath: "/private/tmp/wink-browser-session-transport-test.sock",
            requestTimeoutSec: 0.1
        )
        let supported = Self.handshake(hostKind: hostKind)
        let supportedServices = RuntimeHostResolver.remoteServices(
            client: client,
            handshake: supported,
            options: CommandRuntimeOptions()
        )
        let supportedBrowser = try #require(supportedServices.browser as? RemoteBrowserMCPClient)
        #expect(supportedBrowser.hasScopedSessionTransport)

        for unsupported in [
            Self.handshake(minor: 37, hostKind: hostKind),
            Self.handshake(hostKind: hostKind, includeCapability: false),
            Self.handshake(hostKind: .helper),
            Self.handshake(hostKind: .inProcess),
        ] {
            let services = RuntimeHostResolver.remoteServices(
                client: client,
                handshake: unsupported,
                options: CommandRuntimeOptions()
            )
            let browser = try #require(services.browser as? RemoteBrowserMCPClient)
            #expect(!browser.hasScopedSessionTransport)
        }
    }

    @Test(arguments: [WinkBridgeHostKind.onDemand, .gui], Self.operations)
    func `capability policy requires every scoped browser operation supported and enabled`(
        hostKind: WinkBridgeHostKind,
        operation: WinkBridgeOperation
    ) {
        #expect(BridgeCapabilityPolicy.supportsBrowserConnectionHandoff(for: Self.handshake(hostKind: hostKind)))
        #expect(!BridgeCapabilityPolicy.supportsBrowserConnectionHandoff(
            for: Self.handshake(hostKind: hostKind, omitting: operation)
        ))
        #expect(!BridgeCapabilityPolicy.supportsBrowserConnectionHandoff(
            for: Self.handshake(hostKind: hostKind, disabling: operation)
        ))
    }

    private nonisolated static let operations: [WinkBridgeOperation] = [
        .browserStatus,
        .browserConnect,
        .browserExecute,
        .browserSessionBootstrap,
        .browserSessionControl,
    ]

    private static func handshake(
        minor: Int = 38,
        hostKind: WinkBridgeHostKind = .onDemand,
        includeCapability: Bool = true,
        omitting operationToOmit: WinkBridgeOperation? = nil,
        disabling disabledOperation: WinkBridgeOperation? = nil
    ) -> WinkBridgeHandshakeResponse {
        let supported = self.operations.filter { $0 != operationToOmit }
        let enabled = supported.filter { $0 != disabledOperation }
        return WinkBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: minor),
            hostKind: hostKind,
            build: nil,
            supportedOperations: supported,
            enabledOperations: enabled,
            hostCapabilities: includeCapability ? [WinkBridgeHostCapability.browserConnectionHandoff] : []
        )
    }
}
