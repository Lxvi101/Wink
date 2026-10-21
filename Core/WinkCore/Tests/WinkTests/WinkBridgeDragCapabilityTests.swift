import Foundation
import WinkBridge
import WinkBridgeTestSupport
import Testing

struct WinkBridgeDragCapabilityTests {
    private static let requiredCapabilities = [
        WinkBridgeHostCapability.exactWindowDrag,
        WinkBridgeHostCapability.attestedOperationReceipts,
    ]

    @Test(arguments: [38, 39, 40])
    func `drag support preserves every negotiated gate`(minor: Int) {
        let capabilities: [(names: [String]?, complete: Bool)] = [
            (nil, false),
            ([], false),
            ([WinkBridgeHostCapability.exactWindowDrag], false),
            ([WinkBridgeHostCapability.attestedOperationReceipts], false),
            (Self.requiredCapabilities, true),
        ]
        let enabledOptions: [[WinkBridgeOperation]?] = [nil, [], [.drag], [.exactWindowDrag]]
        for advertised in [false, true] {
            let supported: [WinkBridgeOperation] = advertised ? [.drag, .exactWindowDrag] : [.drag]
            for enabled in enabledOptions where advertised || enabled != [.exactWindowDrag] {
                for capability in capabilities {
                    let handshake = BridgeTestFixtures.handshake(
                        negotiatedVersion: .init(major: 1, minor: minor),
                        supportedOperations: supported,
                        enabledOperations: enabled,
                        hostCapabilities: capability.names)
                    let expected = minor >= 39 && capability.complete && advertised &&
                        (enabled == nil || enabled == [.exactWindowDrag])
                    #expect(handshake.supportsExactWindowDrag == expected)
                }
            }
        }
    }

    @Test
    func `an enabled but unadvertised drag cannot grant support`() throws {
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 39),
            supportedOperations: [.exactWindowDrag],
            enabledOperations: [.exactWindowDrag],
            hostCapabilities: Self.requiredCapabilities)
        var wire = try JSONDecoder().decode(
            [String: WinkBridgeJSONValue].self,
            from: JSONEncoder().encode(handshake))
        wire["supportedOperations"] = .array([])
        let malformed = try JSONDecoder().decode(
            WinkBridgeHandshakeResponse.self,
            from: JSONEncoder().encode(wire))

        #expect(!malformed.supportsExactWindowDrag)
    }

    @Test(arguments: [false, true])
    func `derived support keeps wire shape and omitted enabled fallback`(explicitlyDisabled: Bool) throws {
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 39),
            supportedOperations: [.exactWindowDrag],
            enabledOperations: explicitlyDisabled ? [] : nil,
            hostCapabilities: Self.requiredCapabilities)
        let data = try JSONEncoder().encode(handshake)
        let wire = try JSONDecoder().decode([String: WinkBridgeJSONValue].self, from: data)
        let decoded = try JSONDecoder().decode(WinkBridgeHandshakeResponse.self, from: data)

        #expect(wire["supportsExactWindowDrag"] == nil)
        #expect((wire["enabledOperations"] != nil) == explicitlyDisabled)
        #expect(decoded.supportsExactWindowDrag == !explicitlyDisabled)
    }
}
