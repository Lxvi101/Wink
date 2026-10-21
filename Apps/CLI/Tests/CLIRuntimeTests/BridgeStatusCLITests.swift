import Commander
import Foundation
import WinkAutomationKit
import WinkBridge
import WinkBridgeTestSupport
import Subprocess
import Testing
@testable import WinkCLI

struct BridgeStatusCLITests {
    @Test
    func `implicit unauthorized daemon rejection warns before verbose diagnostics`() async throws {
        guard TestChildProcess.canLocateWinkBinary() else {
            Issue.record("Build wink before running CLI runtime tests.")
            return
        }

        let refusal = WinkBridgeResponse.error(.init(
            code: .unauthorizedClient,
            message: "Team TEST is not authorized"
        ))
        let peer = try ScriptedBridgePeer(responses: [refusal, refusal])
        let result = try await TestChildProcess.runWink(
            ["bridge", "status"],
            environment: [
                "WINK_BRIDGE_SOCKET": "",
                "WINK_DAEMON_SOCKET": peer.socketPath,
            ],
            isolateFromRemoteHosts: false
        )
        await peer.waitUntilFinished()

        #expect(result.status == .exited(0))
        #expect(result.standardError.isEmpty)
        #expect(result.standardOutput.contains("Selected: local (in-process)"))
        #expect(result.standardOutput.contains("eligible remote Bridge hosts were rejected"))
        #expect(result.standardOutput.contains(peer.socketPath))
        #expect(result.standardOutput.contains("unauthorizedClient"))
        #expect(!result.standardOutput.contains("Candidates:"))
    }

    @Test
    func `implicit unauthorized rejection JSON preserves the established report`() async throws {
        guard TestChildProcess.canLocateWinkBinary() else {
            Issue.record("Build wink before running CLI runtime tests.")
            return
        }

        let refusal = WinkBridgeResponse.error(.init(
            code: .unauthorizedClient,
            message: "Team TEST is not authorized"
        ))
        let peer = try ScriptedBridgePeer(responses: [refusal, refusal])
        let result = try await TestChildProcess.runWink(
            ["bridge", "status", "--json"],
            environment: [
                "WINK_BRIDGE_SOCKET": "",
                "WINK_DAEMON_SOCKET": peer.socketPath,
            ],
            isolateFromRemoteHosts: false
        )
        await peer.waitUntilFinished()

        #expect(result.status == .exited(0))
        #expect(result.standardError.isEmpty)
        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let envelope = try #require(object as? [String: Any])
        let data = try #require(envelope["data"] as? [String: Any])
        let selected = try #require(data["selected"] as? [String: Any])
        let candidates = try #require(data["candidates"] as? [[String: Any]])
        let candidate = try #require(candidates.first)
        #expect(selected["source"] as? String == "local")
        #expect(Set(data.keys) == ["remoteSkipped", "selected", "candidates", "client"])
        #expect(Set(candidate.keys) == ["socketPath", "result"])
        #expect(candidate["socketPath"] as? String == peer.socketPath)
        #expect(candidate["selectionEligible"] == nil)
        #expect(candidate["rejection"] == nil)
        #expect(data["fallback"] == nil)
        #expect(data["diagnostics"] == nil)
    }

    @Test
    func `Middle and triple clicks require complete negotiated stateless support`() throws {
        for flag in ["middle", "triple"] {
            let options = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: [], options: ["on": ["B1"]], flags: [flag]),
                commandType: ClickCommand.self
            )
            #expect(options.requiresStatelessClickVariants)
            #expect(options.requiresBackgroundStatelessClickVariants)
            #expect(options.requiresPostEventPermission)

            let foreground = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(
                    positional: [],
                    options: ["on": ["B1"]],
                    flags: [flag, "foreground"]
                ),
                commandType: ClickCommand.self
            )
            #expect(foreground.requiresStatelessClickVariants)
            #expect(!foreground.requiresBackgroundStatelessClickVariants)
        }

        let operations: [WinkBridgeOperation] = [.targetedClick, .exactWindowTargetedClick]
        let permissions = PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
        let incomplete = [
            BridgeTestFixtures.handshake(
                negotiatedVersion: .init(major: 1, minor: 29),
                supportedOperations: operations,
                permissions: permissions,
                hostCapabilities: [WinkBridgeHostCapability.statelessClickVariants]
            ),
            BridgeTestFixtures.handshake(
                negotiatedVersion: WinkBridgeConstants.statelessClickVariantVersion,
                supportedOperations: operations,
                permissions: permissions
            ),
            BridgeTestFixtures.handshake(
                negotiatedVersion: WinkBridgeConstants.statelessClickVariantVersion,
                supportedOperations: [.exactWindowTargetedClick],
                permissions: permissions,
                hostCapabilities: [WinkBridgeHostCapability.statelessClickVariants]
            ),
            BridgeTestFixtures.handshake(
                negotiatedVersion: WinkBridgeConstants.statelessClickVariantVersion,
                supportedOperations: [.targetedClick],
                permissions: permissions,
                hostCapabilities: [WinkBridgeHostCapability.statelessClickVariants]
            ),
            BridgeTestFixtures.handshake(
                negotiatedVersion: WinkBridgeConstants.statelessClickVariantVersion,
                supportedOperations: operations,
                permissions: permissions,
                enabledOperations: [.exactWindowTargetedClick],
                hostCapabilities: [WinkBridgeHostCapability.statelessClickVariants]
            ),
            BridgeTestFixtures.handshake(
                negotiatedVersion: WinkBridgeConstants.statelessClickVariantVersion,
                supportedOperations: operations,
                permissions: permissions,
                enabledOperations: [.targetedClick],
                hostCapabilities: [WinkBridgeHostCapability.statelessClickVariants]
            ),
        ]
        var options = CommandRuntimeOptions()
        options.requiresStatelessClickVariants = true
        options.requiresBackgroundStatelessClickVariants = true
        for handshake in incomplete {
            #expect(!CommandRuntime.supportsRemoteRequirements(for: handshake, options: options))
        }

        let capable = BridgeTestFixtures.handshake(
            negotiatedVersion: WinkBridgeConstants.statelessClickVariantVersion,
            supportedOperations: operations,
            permissions: permissions,
            hostCapabilities: [WinkBridgeHostCapability.statelessClickVariants]
        )
        #expect(CommandRuntime.supportsRemoteRequirements(for: capable, options: options))

        var foregroundOptions = CommandRuntimeOptions()
        foregroundOptions.requiresStatelessClickVariants = true
        let foregroundCapable = BridgeTestFixtures.handshake(
            negotiatedVersion: WinkBridgeConstants.statelessClickVariantVersion,
            supportedOperations: [.click],
            permissions: permissions
        )
        #expect(CommandRuntime.supportsRemoteRequirements(
            for: foregroundCapable,
            options: foregroundOptions
        ))
        let foregroundLegacy = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 29),
            supportedOperations: [.click],
            permissions: permissions
        )
        #expect(!CommandRuntime.supportsRemoteRequirements(
            for: foregroundLegacy,
            options: foregroundOptions
        ))
    }

    struct MalformedRequestCase: Sendable {
        let arguments: [String]
        let expectedMessage: String
    }

    @Test(arguments: [
        MalformedRequestCase(
            arguments: ["click", "--at", "not-a-coordinate"],
            expectedMessage: "Invalid coordinates format. Use: x,y"
        ),
        MalformedRequestCase(
            arguments: ["move", "--at", "not-a-coordinate", "--foreground"],
            expectedMessage: "Invalid coordinates format. Use: x,y"
        ),
        MalformedRequestCase(
            arguments: ["type", "--profile", "human"],
            expectedMessage: "No input specified. Provide text or use --clear."
        ),
        MalformedRequestCase(
            arguments: [
                "drag", "--from", "source_id", "--to", "target_id", "--button", "middle", "--foreground",
            ],
            expectedMessage: "--button must be either 'left' or 'right'"
        ),
    ])
    func `malformed requests fail before explicit Bridge resolution`(testCase: MalformedRequestCase) async throws {
        guard TestChildProcess.canLocateWinkBinary() else {
            Issue.record("Build wink before running CLI runtime tests.")
            return
        }

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("wink-missing-bridge-\(UUID().uuidString).sock").path
        var arguments = testCase.arguments
        arguments += ["--bridge-socket", socketPath, "--json"]

        let result = try await TestChildProcess.runWink(
            arguments,
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(1))
        #expect(result.standardError.isEmpty)

        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        let outcome = try #require(json["outcome"] as? [String: Any])
        #expect(json["success"] as? Bool == false)
        #expect(json["effect"] as? String == "refused")
        #expect(error["code"] as? String == "VALIDATION_ERROR")
        #expect(error["message"] as? String == testCase.expectedMessage)
        #expect(error["mutation_dispatched"] as? Bool == false)
        #expect(error["retry_safe"] as? Bool == true)
        #expect(outcome["dispatch_state"] as? String == "none")
        #expect(outcome["state"] as? String == "refused")
        #expect(!result.standardOutput.contains("BRIDGE_UNAVAILABLE"))
        #expect(!result.standardOutput.contains(socketPath))
        #expect(!result.standardOutput.contains("Runtime host:"))
    }

    @Test
    func `explicit missing Bridge socket fails without local fallback`() async throws {
        guard TestChildProcess.canLocateWinkBinary() else {
            Issue.record("Build wink before running CLI runtime tests.")
            return
        }

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("wink-missing-bridge-\(UUID().uuidString).sock").path
        let result = try await TestChildProcess.runWink(
            [
                "bridge", "status",
                "--bridge-socket", socketPath,
                "--json",
            ],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(1))
        #expect(result.standardError.isEmpty)

        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(json["success"] as? Bool == false)
        #expect(json["data"] is NSNull)
        #expect(error["code"] as? String == "BRIDGE_UNAVAILABLE")
        #expect((error["message"] as? String)?.contains(socketPath) == true)
        #expect((error["hint"] as? String)?.contains("--no-remote") == true)
        #expect(!result.standardOutput.contains(#""source" : "local""#))
        #expect(!result.standardOutput.contains("remoteCandidatesRejected"))
        #expect(!result.standardOutput.contains(#""fallback""#))
    }

    @Test
    func `explicit missing Bridge socket blocks runtime command local fallback`() async throws {
        guard TestChildProcess.canLocateWinkBinary() else {
            Issue.record("Build wink before running CLI runtime tests.")
            return
        }

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("wink-missing-bridge-\(UUID().uuidString).sock").path
        let result = try await TestChildProcess.runWink(
            [
                "app", "list",
                "--bridge-socket", socketPath,
                "--json",
            ],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(1))
        #expect(result.standardError.isEmpty)

        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(json["success"] as? Bool == false)
        #expect(json["data"] is NSNull)
        #expect(error["code"] as? String == "BRIDGE_UNAVAILABLE")
        #expect((error["message"] as? String)?.contains(socketPath) == true)
        #expect(!result.standardOutput.contains(#""apps""#))
    }

    @Test
    func `explicit missing Bridge socket blocks middle click local fallback`() async throws {
        guard TestChildProcess.canLocateWinkBinary() else {
            Issue.record("Build wink before running CLI runtime tests.")
            return
        }

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("wink-missing-middle-click-\(UUID().uuidString).sock").path
        let result = try await TestChildProcess.runWink(
            [
                "click", "--on", "B1", "--snapshot", "ps1_00000000000000000000000000000001", "--middle",
                "--bridge-socket", socketPath,
                "--json",
            ],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(1))
        #expect(result.standardError.isEmpty)

        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(json["success"] as? Bool == false)
        #expect(error["code"] as? String == "SNAPSHOT_NOT_FOUND")
        #expect((error["message"] as? String)?.contains(socketPath) == true)
        #expect(!result.standardOutput.contains("Runtime host: local"))
    }

    @Test
    func `no remote explicitly permits local execution alongside a socket override`() async throws {
        guard TestChildProcess.canLocateWinkBinary() else {
            Issue.record("Build wink before running CLI runtime tests.")
            return
        }

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("wink-missing-bridge-\(UUID().uuidString).sock").path
        let result = try await TestChildProcess.runWink(
            [
                "screen", "list",
                "--bridge-socket", socketPath,
                "--no-remote",
                "--json",
            ],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(0))
        #expect(result.standardError.isEmpty)

        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let data = try #require(json["data"] as? [String: Any])
        #expect(json["success"] as? Bool == true)
        #expect(data["screens"] is [[String: Any]])
        #expect(!result.standardOutput.contains("BRIDGE_UNAVAILABLE"))
    }

    @Test
    func `human explicit missing Bridge socket reports the endpoint on stderr`() async throws {
        guard TestChildProcess.canLocateWinkBinary() else {
            Issue.record("Build wink before running CLI runtime tests.")
            return
        }

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("wink-missing-bridge-\(UUID().uuidString).sock").path
        let result = try await TestChildProcess.runWink(
            [
                "bridge", "status",
                "--bridge-socket", socketPath,
            ],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(1))
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.contains(socketPath))
        #expect(result.standardError.contains("--no-remote"))
        #expect(!result.standardError.contains("Selected: local"))
    }
}
