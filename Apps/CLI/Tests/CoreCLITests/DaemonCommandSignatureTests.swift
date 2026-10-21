import Testing
@testable import WinkCLI

struct DaemonCommandSignatureTests {
    @Test
    func `Daemon commands share the canonical bridge socket option`() throws {
        let arguments = ["--bridge-socket", "/tmp/wink-test.sock"]

        #expect(try DaemonCommand.Start.parse(arguments).bridgeSocket == "/tmp/wink-test.sock")
        #expect(try DaemonCommand.Stop.parse(arguments).bridgeSocket == "/tmp/wink-test.sock")
        #expect(try DaemonCommand.Status.parse(arguments).bridgeSocket == "/tmp/wink-test.sock")
        #expect(try DaemonCommand.Run.parse(arguments).bridgeSocket == "/tmp/wink-test.sock")
    }
}
