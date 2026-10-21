import Commander
import Testing
@testable import WinkCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct CommanderRuntimeArgvTests {
    @Test(arguments: ["/tmp/wink-before", "pb", "wink-4.9", "wink", "/usr/local/bin/wink"])
    func `router resolves command help for any executable name`(executable: String) {
        let exitCode = #expect(throws: ExitCode.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: [executable, "see", "--help"])
        }
        #expect(exitCode == .success)
    }

    @Test(arguments: ["/tmp/wink-before", "pb", "wink-4.9", "wink", "/usr/local/bin/wink"])
    func `router drops exactly the executable before resolving a command`(executable: String) throws {
        let resolved = try CommanderRuntimeRouter.resolve(argv: [executable, "config", "show"])
        #expect(resolved.metadata.name == "show")
        #expect(ObjectIdentifier(resolved.type) == ObjectIdentifier(ConfigCommand.ShowCommand.self))
        #expect(resolved.parsedValues.positional.isEmpty)
    }

    @Test(
        arguments: ["/tmp/wink-before", "pb", "wink-4.9", "wink", "/usr/local/bin/wink"],
        [["--version"], ["see", "--help"]]
    )
    func `entry point handles version and help for any executable name`(
        executable: String,
        arguments: [String]
    ) async {
        let exitCode = await executeWinkCLI(arguments: [executable] + arguments)
        #expect(exitCode == 0)
    }
}
