import Commander
import Testing
@testable import WinkCLI

@Suite(.tags(.safe))
@MainActor
struct HumanizedInputCommandTests {
    @Test
    func `humanized typing accepts WPM and rejects a linear profile`() throws {
        var command = try TypeCommand.parse(["Hello", "--humanized", "--wpm", "140"])
        #expect(command.humanized)
        try command.validate()
        var conflicting = try TypeCommand.parse(["Hello", "--humanized", "--profile", "linear"])
        #expect(throws: ValidationError.self) { try conflicting.validate() }
    }

    @Test
    func `humanized scroll requires explicit foreground and compatible options`() throws {
        let command = try ScrollCommand.parse(["--direction", "down", "--humanized", "--foreground"])
        #expect(command.humanized)
        try command.validateBeforeRuntime()
        for options in [[], ["--foreground", "--smooth"], ["--foreground", "--amount", "51"]] {
            let invalid = try ScrollCommand.parse(["--direction", "down", "--humanized"] + options)
            #expect(throws: (any Error).self) { try invalid.validateBeforeRuntime() }
        }
    }
}
