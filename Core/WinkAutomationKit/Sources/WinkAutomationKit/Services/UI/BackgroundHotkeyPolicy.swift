import CoreGraphics
import Foundation
import WinkFoundation

/// Rejects process-targeted shortcuts whose effects cannot be verified at the keyboard-event boundary.
public enum BackgroundHotkeyPolicy {
    /// Validates that a hotkey is safe to report as delivered in the background.
    ///
    /// Process-targeted CoreGraphics events have no acknowledgement from the receiving app. Lifecycle and
    /// window-management shortcuts therefore use Wink's semantic commands, which can verify their effects.
    public static func validate(keys: String) throws {
        let parsedKeys = try HotkeyService.parsedKeys(keys)
        let plan = try HotkeyService.HotkeyChord(keys: parsedKeys).plan

        guard plan.modifierFlags == .maskCommand,
              let alternative = Self.semanticAlternative(for: plan.primaryKey)
        else {
            return
        }

        let chord = "Cmd+\(plan.primaryKey.uppercased())"
        throw WinkError.invalidInput(
            "Background \(chord) cannot be verified after process-targeted delivery. " +
                "Use `\(alternative)` for verified background behavior, or add `--foreground` " +
                "to send \(chord) explicitly.")
    }

    private static func semanticAlternative(for primaryKey: String) -> String? {
        switch primaryKey {
        case "w":
            "wink window close --app <app>"
        case "q":
            "wink app quit --app <app>"
        case "h":
            "wink app hide --app <app>"
        case "m":
            "wink window minimize --app <app>"
        default:
            nil
        }
    }
}
