import Commander
import Testing
@testable import WinkCLI

@Suite(.tags(.fast))
@MainActor
struct CommanderMigrationAdvisorTests {
    @Test(arguments: [
        (["image"], "wink see --no-elements"),
        (["inspect-ui"], "wink see --tree --no-screenshot"),
        (["hotkey"], "wink press"),
        (["swipe"], "wink drag"),
        (["perform-action"], "wink action"),
        (["list", "windows"], "wink window list"),
        (["help", "image"], "wink see --no-elements"),
    ])
    func `Removed commands name their replacement`(arguments: [String], replacement: String) throws {
        let error = try #require(CommanderMigrationAdvisor.commandError(for: arguments))
        #expect(error.localizedDescription.contains("removed in v4"))
        #expect(error.localizedDescription.contains(replacement))
    }

    @Test(arguments: [
        (["click", "--coords", "1,2"], "--at"),
        (["paste", "--restore-delay-ms", "100"], "--restore-delay"),
        (["capture", "video", "in.mov", "--every-ms", "500"], "--every"),
        (["type", "hello", "--return"], "wink press Return --foreground"),
        (["agent", "--resume-session", "abc"], "wink agent resume <session-id>"),
        (["clipboard", "--action", "get"], "clipboard status|get|set|clear|save|restore"),
    ])
    func `Removed options name their replacement`(arguments: [String], replacement: String) throws {
        let error = try #require(CommanderMigrationAdvisor.optionError(for: arguments))
        #expect(error.localizedDescription.contains(replacement))
    }

    @Test
    func `Migration scanning stops at positional terminator`() {
        #expect(CommanderMigrationAdvisor.optionError(for: ["type", "--", "--coords"]) == nil)
    }

    @Test
    func `Router returns migration advice instead of generic parser errors`() {
        #expect(throws: CommanderUsageError.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: ["wink", "image"])
        }
        #expect(throws: CommanderUsageError.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: ["wink", "click", "--coords", "1,2"])
        }
        #expect(throws: CommanderUsageError.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: ["wink", "--json", "see"])
        }
    }
}
