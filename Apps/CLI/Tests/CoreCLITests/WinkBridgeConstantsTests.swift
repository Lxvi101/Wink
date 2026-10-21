import WinkBridge
import Testing

struct WinkBridgeConstantsTests {
    @Test
    func `Wink host sockets have distinct roles`() {
        #expect(WinkBridgeConstants.winkSocketPath.hasSuffix("/Wink/bridge.sock"))
        #expect(WinkBridgeConstants.daemonSocketPath.hasSuffix("/Wink/daemon.sock"))
    }

    @Test
    func `Claude socket path uses Application Support/Claude`() {
        #expect(WinkBridgeConstants.claudeSocketPath.hasSuffix("/Claude/bridge.sock"))
    }

    @Test
    func `Release bridge accepts legacy and Foundation signing teams`() {
        #expect(WinkBridgeConstants.trustedReleaseTeamIDs == ["Y5PE65HELJ", "FWJYW4S8P8"])
    }
}
