import Foundation
import WinkBridge
import Testing
@testable import WinkCLI

@Suite(.tags(.safe))
struct DaemonHistoricalCleanupTests {
    @Test
    func `only automatic build scoped daemons own deferred historical cleanup`() {
        let defaultSocketURL = URL(fileURLWithPath: WinkBridgeConstants.daemonSocketPath)
        let buildSocketPath = defaultSocketURL.deletingLastPathComponent()
            .appendingPathComponent("daemon-aaaaaaaaaaaaaaaa.sock").path

        #expect(DaemonCommand.Run.shouldScheduleHistoricalCleanup(.auto(
            bridgeSocketPath: buildSocketPath
        )))
        #expect(!DaemonCommand.Run.shouldScheduleHistoricalCleanup(.manual(
            bridgeSocketPath: buildSocketPath
        )))
        #expect(!DaemonCommand.Run.shouldScheduleHistoricalCleanup(.auto(
            bridgeSocketPath: WinkBridgeConstants.daemonSocketPath
        )))
        #expect(!DaemonCommand.Run.shouldScheduleHistoricalCleanup(.auto(
            bridgeSocketPath: "/tmp/daemon-aaaaaaaaaaaaaaaa.sock"
        )))
    }
}
