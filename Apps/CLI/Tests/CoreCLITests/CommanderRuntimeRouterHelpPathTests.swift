import Commander
import Testing
@testable import WinkCLI

@MainActor
struct CommanderRuntimeRouterHelpPathTests {
    @Test(arguments: [
        ["wink", "--junk", "--help"],
        ["wink", "--junk", "-h"],
        ["wink", "--json", "--help"],
        ["wink", "help", "--junk"],
        ["wink", "--junk", "--version"],
        ["wink", "--junk", "-V"],
        ["wink", "--json", "--version"],
        ["wink", "--log-level", "debug", "--version"],
        ["wink", "--logLevel=debug", "-V"],
        ["wink", "--bridge-socket", "/tmp/missing.sock", "--help"],
        ["wink", "--input-strategy", "actionOnly", "-h"],
    ])
    func `root early-exit flags ignore preceding root options`(arguments: [String]) {
        let exitCode = #expect(throws: ExitCode.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: arguments)
        }
        #expect(exitCode == .success)
    }

    @Test
    func `help resolves longest matching command prefix`() {
        let exitCode = #expect(throws: ExitCode.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: ["wink", "help", "app", "list", "extra-token"])
        }
        #expect(exitCode == .success)
    }

    @Test
    func `help ignores option-like trailing tokens`() {
        let exitCode = #expect(throws: ExitCode.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: ["wink", "help", "app", "quit", "--pid", "123"])
        }
        #expect(exitCode == .success)
    }

    @Test(arguments: [
        ["wink", "--junk", "click", "--help"],
        ["wink", "--junk", "app", "--help"],
        ["wink", "--unknown=1", "app", "list", "--help"],
    ])
    func `option-leading command help retains the command path`(arguments: [String]) {
        let exitCode = #expect(throws: ExitCode.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: arguments)
        }
        #expect(exitCode == .success)
    }

    @Test
    func `help tokens after double dash stay in capture action command tail`() throws {
        let resolved = try CommanderRuntimeRouter.resolve(
            argv: ["wink", "capture", "action", "--", "/bin/echo", "--help"]
        )

        #expect(ObjectIdentifier(resolved.type) == ObjectIdentifier(CaptureActionCommand.self))
        #expect(resolved.parsedValues.positional == ["/bin/echo", "--help"])
        #expect(resolved.parsedValues.options["command"] == nil)
    }

    @Test(arguments: [
        ["wink", "does-not-exist", "--help"],
        ["wink", "--junk", "does-not-exist", "--help"],
    ])
    func `unknown positional help target remains an error`(arguments: [String]) {
        let error = #expect(throws: CommanderProgramError.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: arguments)
        }
        #expect(error == .unknownCommand("does-not-exist"))
    }

    @Test(arguments: [
        ["wink", "--log-level", "--help"],
        ["wink", "--logLevel", "--help"],
        ["wink", "--bridge-socket", "--help"],
        ["wink", "--bridgeSocket", "--help"],
        ["wink", "--input-strategy", "--help"],
        ["wink", "--inputStrategy", "--help"],
    ])
    func `missing runtime option value does not become root help`(arguments: [String]) {
        let error = #expect(throws: CommanderUsageError.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: arguments)
        }
        #expect(error?.message.contains("Runtime flags must follow the leaf command") == true)
    }

    @Test(arguments: [
        ["wink", "--log-level=--help"],
        ["wink", "--logLevel=--help"],
    ])
    func `attached help token remains a runtime option value`(arguments: [String]) {
        let error = #expect(throws: CommanderProgramError.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: arguments)
        }
        #expect(error == .unknownCommand(arguments[1]))
    }

    @Test
    func `early-exit flags after double dash remain ordinary arguments`() {
        do {
            _ = try CommanderRuntimeRouter.resolve(argv: ["wink", "--junk", "--", "--help"])
            Issue.record("Expected an argument error")
        } catch let exitCode as ExitCode {
            #expect(exitCode != .success)
        } catch {
            // Any ordinary parser error proves the root help short-circuit did not run.
        }
    }

    @Test
    func `leaf version remains an option error`() {
        do {
            _ = try CommanderRuntimeRouter.resolve(argv: ["wink", "click", "--version"])
            Issue.record("Expected an option error")
        } catch let exitCode as ExitCode {
            #expect(exitCode != .success)
        } catch {
            // Expected: version is a root early-exit flag, not a leaf command option.
        }
    }
}
