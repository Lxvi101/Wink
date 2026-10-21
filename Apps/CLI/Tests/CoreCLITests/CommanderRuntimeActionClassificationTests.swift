import Testing
@testable import WinkCLI

@MainActor
struct CommanderRuntimeActionClassificationTests {
    @Test
    func `every registered leaf follows ActionOutputFormattable classification`() {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        for (path, descriptor) in Self.leafDescriptors(descriptors) {
            let expected = (descriptor.type.init() as? any ActionOutputFormattable)?.defaultEffect != nil
            for arguments in [
                ["/tmp/wink-before"] + path,
                ["pb"] + path,
                ["wink-4.9"] + path + ["--json"],
                ["wink"] + path,
                ["/usr/local/bin/wink"] + path,
                ["/tmp/wink"] + path + ["--json"],
                ["wink"] + path + ["--", "--json"],
            ] {
                let actual = CommanderRuntimeRouter.isActionInvocation(argv: arguments)
                #expect(
                    actual == expected,
                    "Incorrect result-envelope classification for \(arguments.joined(separator: " "))"
                )
            }
        }
    }

    @Test(arguments: ["wink", "/tmp/wink-before", "pb", "wink-4.9"])
    func `omitted default subcommands keep the registered leaf classification`(executable: String) throws {
        for descriptor in CommanderRegistryBuilder.buildDescriptors() {
            guard let defaultName = descriptor.metadata.defaultSubcommandName else { continue }
            let defaultCommand = try #require(descriptor.subcommands.first { $0.metadata.name == defaultName })
            let expected = (defaultCommand.type.init() as? any ActionOutputFormattable)?.defaultEffect != nil
            for suffix in [[], ["--json"], ["--unknown-option"], ["--", "--json"]] {
                let arguments = [executable, descriptor.metadata.name] + suffix
                #expect(CommanderRuntimeRouter.isActionInvocation(argv: arguments) == expected)
            }
        }
    }

    @Test
    func `unknown and incomplete command paths are not actions`() {
        #expect(!CommanderRuntimeRouter.isActionInvocation(argv: []))
        #expect(!CommanderRuntimeRouter.isActionInvocation(argv: ["wink"]))
        #expect(!CommanderRuntimeRouter.isActionInvocation(argv: ["wink", "--json", "--version"]))
        #expect(!CommanderRuntimeRouter.isActionInvocation(argv: ["wink", "unknown", "--json"]))
        #expect(!CommanderRuntimeRouter.isActionInvocation(argv: ["wink", "window", "--json"]))
        #expect(!CommanderRuntimeRouter.isActionInvocation(argv: ["wink", "window", "unknown", "--json"]))
    }

    @Test
    func `capture selector shapes stay read-only while window and space mutations are actions`() {
        let captureShapes = [
            ["wink", "capture", "live", "--app", "Example", "--pid", "123", "--json"],
            ["wink", "capture", "live", "--window-title", "Main", "--window-index", "0", "--json"],
            [
                "wink", "capture", "live", "--mode", "screen", "--screen-index", "0", "--app", "Example",
                "--json",
            ],
        ]
        for argv in captureShapes {
            #expect(!CommanderRuntimeRouter.isActionInvocation(argv: argv))
        }

        #expect(CommanderRuntimeRouter.isActionInvocation(argv: [
            "wink", "window", "close", "--window-title", "Main", "--window-index", "0", "--json",
        ]))
        #expect(CommanderRuntimeRouter.isActionInvocation(argv: [
            "wink", "space", "move-window", "--app", "Example", "--pid", "123", "--to", "1", "--json",
        ]))
    }

    private static func leafDescriptors(
        _ descriptors: [CommanderCommandDescriptor],
        prefix: [String] = []
    ) -> [(path: [String], descriptor: CommanderCommandDescriptor)] {
        descriptors.flatMap { descriptor in
            let path = prefix + [descriptor.metadata.name]
            guard !descriptor.subcommands.isEmpty else { return [(path, descriptor)] }
            return self.leafDescriptors(descriptor.subcommands, prefix: path)
        }
    }
}
