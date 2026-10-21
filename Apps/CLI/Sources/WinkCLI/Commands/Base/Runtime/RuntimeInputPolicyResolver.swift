import Foundation
import WinkAutomation
import WinkAutomationKit

enum RuntimeInputPolicyResolver {
    static func hasEnvironmentOverride(environment: [String: String]) -> Bool {
        [
            "WINK_INPUT_STRATEGY",
            "WINK_CLICK_INPUT_STRATEGY",
            "WINK_SCROLL_INPUT_STRATEGY",
            "WINK_TYPE_INPUT_STRATEGY",
            "WINK_HOTKEY_INPUT_STRATEGY",
            "WINK_SET_VALUE_INPUT_STRATEGY",
            "WINK_PERFORM_ACTION_INPUT_STRATEGY",
        ].contains { key in
            guard let value = environment[key] else {
                return false
            }
            return UIInputStrategy(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }
    }

    static func hasConfigOverride(input: WinkAutomation.Configuration.InputConfig?) -> Bool {
        guard let input else {
            return false
        }

        if input.defaultStrategy != nil ||
            input.click != nil ||
            input.scroll != nil ||
            input.type != nil ||
            input.hotkey != nil ||
            input.setValue != nil ||
            input.performAction != nil {
            return true
        }

        return input.perApp?.values.contains { appInput in
            appInput.defaultStrategy != nil ||
                appInput.click != nil ||
                appInput.scroll != nil ||
                appInput.type != nil ||
                appInput.hotkey != nil ||
                appInput.setValue != nil ||
                appInput.performAction != nil
        } ?? false
    }
}
