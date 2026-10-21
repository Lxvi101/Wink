import ApplicationServices
import Foundation

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin, allocation-light helpers over the raw Accessibility C API.
enum AX {
    static let batchAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXValueAttribute, kAXIdentifierAttribute, kAXEnabledAttribute, kAXFocusedAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute, kAXHelpAttribute,
        kAXPlaceholderValueAttribute, kAXSelectedAttribute,
    ]

    /// Fetches many attributes in one IPC round trip. Missing attributes come back as nil.
    static func attributes(_ element: AXUIElement, _ names: [String]) -> [AnyObject?] {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values
        )
        guard err == .success, let array = values as? [AnyObject], array.count == names.count else {
            return Array(repeating: nil, count: names.count)
        }
        return array.map { value in
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                return nil
            }
            if value is NSNull { return nil }
            return value
        }
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        (attribute(element, name) as? [AXUIElement]) ?? []
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    static func point(_ value: AnyObject?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: AnyObject?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        let values = attributes(element, [kAXPositionAttribute, kAXSizeAttribute])
        guard let origin = point(values[0]), let size = size(values[1]) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func windowID(_ window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
    }

    /// "AXTextField" -> "text field"; subroles win where they carry meaning.
    static func displayRole(role: String?, subrole: String?) -> String {
        let meaningfulSubroles: Set<String> = [
            "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton", "AXSearchField",
            "AXSecureTextField", "AXToggle", "AXSwitch", "AXTabButton", "AXOutlineRow",
        ]
        let raw = (subrole.map { meaningfulSubroles.contains($0) } ?? false) ? subrole! : (role ?? "AXUnknown")
        var name = raw.hasPrefix("AX") ? String(raw.dropFirst(2)) : raw
        if name == "StaticText" { name = "Text" }
        var out = ""
        for (i, ch) in name.enumerated() {
            if ch.isUppercase, i > 0 { out.append(" ") }
            out.append(Character(ch.lowercased()))
        }
        return out
    }

    static func string(_ value: AnyObject?) -> String? {
        switch value {
        case let s as String: return s
        case let a as NSAttributedString: return a.string
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case let u as URL: return u.absoluteString
        default: return nil
        }
    }

    static func bool(_ value: AnyObject?) -> Bool? { (value as? NSNumber)?.boolValue }

    static func errorDescription(_ error: AXError) -> String {
        switch error {
        case .invalidUIElement: "the element no longer exists (UI changed); call get_app_state again"
        case .cannotComplete: "the app did not respond (busy or hung)"
        case .actionUnsupported: "the element does not support that action"
        case .apiDisabled: "Accessibility permission is not granted"
        case .notImplemented: "the app does not implement that accessibility feature"
        case .attributeUnsupported: "the element does not support that attribute"
        default: "accessibility error \(error.rawValue)"
        }
    }
}
