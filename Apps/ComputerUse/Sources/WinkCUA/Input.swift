import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Synthesised input. Background delivery posts straight to the target process so the user's real
/// cursor and focus are left alone; foreground delivery goes through the HID tap.
struct InputTarget {
    let pid: pid_t
    let windowID: CGWindowID?
    let foreground: Bool
}

enum InputError: Error, CustomStringConvertible {
    case unknownKey(String)
    case eventCreation

    var description: String {
        switch self {
        case let .unknownKey(key): "unknown key '\(key)'"
        case .eventCreation: "could not create a CGEvent"
        }
    }
}

enum Input {
    private static let source = CGEventSource(stateID: .privateState)

    private static func post(_ event: CGEvent, _ target: InputTarget) {
        if target.foreground {
            event.post(tap: .cghidEventTap)
        } else {
            event.postToPid(target.pid)
        }
    }

    private static func tagWindow(_ event: CGEvent, _ target: InputTarget) {
        guard let id = target.windowID else { return }
        // Window-under-pointer fields let Cocoa route an event to a window that is not frontmost.
        if let under = CGEventField(rawValue: 91) { event.setIntegerValueField(under, value: Int64(id)) }
        if let handler = CGEventField(rawValue: 92) { event.setIntegerValueField(handler, value: Int64(id)) }
    }

    // MARK: Mouse

    static func click(at point: CGPoint, button: CGMouseButton, count: Int, target: InputTarget) throws {
        let (down, up): (CGEventType, CGEventType) = switch button {
        case .right: (.rightMouseDown, .rightMouseUp)
        case .center: (.otherMouseDown, .otherMouseUp)
        default: (.leftMouseDown, .leftMouseUp)
        }
        if target.foreground {
            CGWarpMouseCursorPosition(point)
        }
        for n in 1...max(1, count) {
            guard let d = CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: point, mouseButton: button),
                  let u = CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: point, mouseButton: button)
            else { throw InputError.eventCreation }
            for e in [d, u] {
                e.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                tagWindow(e, target)
            }
            post(d, target)
            usleep(8000)
            post(u, target)
            if n < count { usleep(25000) }
        }
    }

    static func drag(from: CGPoint, to: CGPoint, target: InputTarget, steps: Int = 16) throws {
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)
        else { throw InputError.eventCreation }
        tagWindow(down, target)
        if target.foreground { CGWarpMouseCursorPosition(from) }
        post(down, target)
        usleep(30000)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            guard let move = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)
            else { throw InputError.eventCreation }
            tagWindow(move, target)
            post(move, target)
            usleep(8000)
        }
        guard let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)
        else { throw InputError.eventCreation }
        tagWindow(up, target)
        post(up, target)
    }

    static func scroll(at point: CGPoint, dx: Int32, dy: Int32, target: InputTarget) throws {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        else { throw InputError.eventCreation }
        event.location = point
        tagWindow(event, target)
        post(event, target)
    }

    // MARK: Keyboard

    static func type(_ text: String, target: InputTarget) throws {
        var buffer: [UniChar] = []
        func flush() throws {
            guard !buffer.isEmpty else { return }
            // CGEvent unicode strings are capped at 20 UTF-16 units per event.
            var start = 0
            while start < buffer.count {
                let end = min(start + 20, buffer.count)
                var chunk = Array(buffer[start..<end])
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                else { throw InputError.eventCreation }
                // Explicitly clear modifiers: otherwise a chord pressed just before (e.g. cmd+n) can leak
                // into the typed text and turn it into shortcuts.
                down.flags = []
                up.flags = []
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                post(down, target)
                post(up, target)
                usleep(2000)
                start = end
            }
            buffer.removeAll()
        }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n", "\r":
                try flush()
                try press("return", target: target)
            case "\t":
                try flush()
                try press("tab", target: target)
            default:
                buffer.append(contentsOf: String(scalar).utf16)
            }
        }
        try flush()
    }

    /// Accepts xdotool/Sky style chords: "cmd+shift+t", "super+c", "Return", "KP_Enter", "ctrl+alt+Delete".
    static func press(_ chord: String, target: InputTarget) throws {
        let parts = chord.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        var flags: CGEventFlags = []
        var keyName = parts.last ?? ""
        if keyName.isEmpty, chord.hasSuffix("+") { keyName = "+" }
        for mod in parts.dropLast() {
            switch mod.lowercased() {
            case "cmd", "command", "super", "meta", "win": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            case "fn": flags.insert(.maskSecondaryFn)
            case "": continue
            default: throw InputError.unknownKey(mod)
            }
        }
        guard let (code, needsShift) = keyCode(for: keyName) else { throw InputError.unknownKey(keyName) }
        if needsShift { flags.insert(.maskShift) }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { throw InputError.eventCreation }
        down.flags = flags
        up.flags = flags
        post(down, target)
        usleep(4000)
        post(up, target)
    }

    static func keyCode(for name: String) -> (CGKeyCode, Bool)? {
        let lower = name.lowercased()
        let named: [String: Int] = [
            "return": kVK_Return, "enter": kVK_Return, "kp_enter": kVK_ANSI_KeypadEnter, "tab": kVK_Tab,
            "space": kVK_Space, "escape": kVK_Escape, "esc": kVK_Escape, "backspace": kVK_Delete,
            "delete": kVK_Delete, "forwarddelete": kVK_ForwardDelete, "forward_delete": kVK_ForwardDelete,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "page_up": kVK_PageUp, "prior": kVK_PageUp,
            "pagedown": kVK_PageDown, "page_down": kVK_PageDown, "next": kVK_PageDown, "help": kVK_Help,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
            "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
            "kp_0": kVK_ANSI_Keypad0, "kp_1": kVK_ANSI_Keypad1, "kp_2": kVK_ANSI_Keypad2, "kp_3": kVK_ANSI_Keypad3,
            "kp_4": kVK_ANSI_Keypad4, "kp_5": kVK_ANSI_Keypad5, "kp_6": kVK_ANSI_Keypad6, "kp_7": kVK_ANSI_Keypad7,
            "kp_8": kVK_ANSI_Keypad8, "kp_9": kVK_ANSI_Keypad9, "kp_add": kVK_ANSI_KeypadPlus,
            "kp_subtract": kVK_ANSI_KeypadMinus, "kp_multiply": kVK_ANSI_KeypadMultiply,
            "kp_divide": kVK_ANSI_KeypadDivide, "kp_decimal": kVK_ANSI_KeypadDecimal, "kp_equal": kVK_ANSI_KeypadEquals,
            "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "plus": kVK_ANSI_Equal, "comma": kVK_ANSI_Comma,
            "period": kVK_ANSI_Period, "slash": kVK_ANSI_Slash, "semicolon": kVK_ANSI_Semicolon,
            "apostrophe": kVK_ANSI_Quote, "grave": kVK_ANSI_Grave, "backslash": kVK_ANSI_Backslash,
            "bracketleft": kVK_ANSI_LeftBracket, "bracketright": kVK_ANSI_RightBracket,
        ]
        if let code = named[lower.replacingOccurrences(of: " ", with: "")] {
            return (CGKeyCode(code), lower == "plus")
        }
        guard name.count == 1, let ch = name.first else { return nil }
        let letters: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
        ]
        let shifted: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
            "_": "-", "+": "=", "{": "[", "}": "]", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "|": "\\",
            "~": "`",
        ]
        if let code = letters[Character(ch.lowercased())] { return (CGKeyCode(code), ch.isUppercase) }
        if let base = shifted[ch], let code = letters[base] { return (CGKeyCode(code), true) }
        return nil
    }
}
