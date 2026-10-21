import Commander
import Foundation

struct CommanderUsageError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? {
        self.message
    }
}

enum CommanderMigrationAdvisor {
    private static let runtimeFlags: Set<String> = {
        let signature = CommandSignature().withWinkRuntimeFlags().flattened()
        return Set(
            signature.options.flatMap { $0.names.map(\.commandLineToken) } +
                signature.flags.flatMap { $0.names.map(\.commandLineToken) }
        )
    }()

    private static let removedRootReplacements: [String: String] = [
        "hotkey": "wink press",
        "swipe": "wink drag",
        "image": "wink see --no-elements",
        "inspect-ui": "wink see --tree --no-screenshot",
        "perform-action": "wink action",
        "sleep": "/bin/sleep",
        "open": "/usr/bin/open, or wink app launch --open <path-or-url> when readiness receipts are needed",
        "run": "a shell script that chains wink commands",
        "commander": "wink --help",
    ]

    private static let removedPathReplacements: [String: String] = [
        "capture watch": "wink capture live",
        "menu click-extra": "wink menubar click",
        "menu list-all": "wink menubar list",
        "agent permission": "wink permissions",
        "config add": "wink config credential set",
        "config add-provider": "wink config provider add",
        "config list-providers": "wink config provider list",
        "config test-provider": "wink config provider test",
        "config remove-provider": "wink config provider remove",
        "config models-provider": "wink config provider models",
        "config set-credential": "wink config credential set",
        "permissions request-accessibility": "wink permissions request accessibility",
        "permissions request-screen-recording": "wink permissions request screen-recording",
        "permissions request-event-synthesizing": "wink permissions request event-synthesizing",
    ]

    private static let removedOptionReplacements: [String: String] = [
        "--app-target": "--app",
        "--autoclean-minutes": "--autoclean",
        "--coords": "--at",
        "--delay-ms": "--delay",
        "--diff-budget-ms": "--diff-budget",
        "--end-ms": "--end",
        "--every-ms": "--every",
        "--focus-timeout-seconds": "--focus-timeout",
        "--from-coords": "--from",
        "--global-coords": "--global",
        "--heartbeat-sec": "--heartbeat",
        "--hold-duration": "--hold",
        "--id": "--on",
        "--idle-timeout-seconds": "--idle-timeout",
        "--image-path": "--file-path",
        "--keys": "positional Wink chords (for example, wink press cmd+c --foreground)",
        "--label": "positional query text or --on",
        "--max-depth": "--depth",
        "--poll-interval-ms": "--poll-interval",
        "--post-roll-ms": "--post-roll",
        "--pre-roll-ms": "--pre-roll",
        "--quiet-ms": "--quiet",
        "--repeat": "--count",
        "--restore-delay-ms": "--restore-delay",
        "--start-ms": "--start",
        "--ticks": "--amount",
        "--timeout-seconds": "--timeout",
        "--to-coords": "--to",
        "--wait-seconds": "--wait",
    ]

    private static let removedAgentModeReplacements: [String: String] = [
        "--chat": "wink agent chat",
        "--list-sessions": "wink agent sessions",
        "--resume": "wink agent resume",
        "--resume-session": "wink agent resume <session-id>",
    ]

    private static let removedTypeKeyReplacements = Set(["--delete", "--escape", "--return", "--tab"])

    static func commandError(for arguments: [String]) -> CommanderUsageError? {
        guard !arguments.isEmpty else { return nil }

        if self.runtimeFlags.contains(arguments[0]) {
            return CommanderUsageError(
                message: "Runtime flags must follow the leaf command. " +
                    "Use 'wink see --json' or 'wink window list --json'."
            )
        }

        let commandTokens = arguments[0] == "help" ? Array(arguments.dropFirst()) : arguments
        guard let root = commandTokens.first else { return nil }

        if root == "list" {
            return Self.removedListError(tokens: commandTokens)
        }

        if let replacement = Self.removedRootReplacements[root] {
            return Self.removedSyntaxError(syntax: "wink \(root)", replacement: replacement)
        }

        if commandTokens.count >= 2 {
            let path = commandTokens.prefix(2).joined(separator: " ")
            if let replacement = Self.removedPathReplacements[path] {
                return Self.removedSyntaxError(syntax: "wink \(path)", replacement: replacement)
            }
        }

        return nil
    }

    static func optionError(for arguments: [String]) -> CommanderUsageError? {
        let tokens = Array(arguments.prefix { $0 != "--" })
        guard let root = tokens.first else { return nil }

        if root == "clipboard", tokens.contains("--action") || tokens.contains("-a") {
            return CommanderUsageError(
                message: "Clipboard action options were removed in v4. " +
                    "Use 'wink clipboard status|get|set|clear|save|restore'."
            )
        }

        if root == "agent" {
            for token in tokens {
                let option = Self.optionName(from: token)
                if let replacement = Self.removedAgentModeReplacements[option] {
                    return Self.removedOptionError(option: option, replacement: replacement)
                }
            }
        }

        if root == "type" {
            for token in tokens {
                let option = Self.optionName(from: token)
                if Self.removedTypeKeyReplacements.contains(option) {
                    let key = String(option.dropFirst(2)).capitalized
                    return Self.removedOptionError(
                        option: option,
                        replacement: "wink press \(key) --foreground"
                    )
                }
            }
        }

        for token in tokens {
            let option = Self.optionName(from: token)
            if let replacement = Self.removedOptionReplacements[option] {
                return Self.removedOptionError(option: option, replacement: replacement)
            }
        }

        return nil
    }

    private static func removedListError(tokens: [String]) -> CommanderUsageError {
        let replacement = switch tokens.dropFirst().first {
        case "apps": "wink app list"
        case "windows": "wink window list"
        case "screens": "wink screen list"
        case "menubar": "wink menubar list"
        case "permissions": "wink permissions status"
        default: "wink app list, wink window list, or wink screen list"
        }
        return Self.removedSyntaxError(syntax: "wink list", replacement: replacement)
    }

    private static func removedSyntaxError(syntax: String, replacement: String) -> CommanderUsageError {
        CommanderUsageError(message: "Command '\(syntax)' was removed in v4. Use '\(replacement)'.")
    }

    private static func removedOptionError(option: String, replacement: String) -> CommanderUsageError {
        CommanderUsageError(message: "Option '\(option)' was removed in v4. Use '\(replacement)'.")
    }

    private static func optionName(from token: String) -> String {
        String(token.prefix { $0 != "=" })
    }
}
