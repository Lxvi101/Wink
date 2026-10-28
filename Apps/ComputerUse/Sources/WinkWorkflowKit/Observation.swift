import Foundation

// Normalized, backend-independent UI observations. Adapters (wink-cua's TreeWalker, tests' mock trees)
// fill these from typed accessibility attributes; nothing here is parsed from rendered text.

public struct Rect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { self.x + self.width / 2 }
    public var midY: Double { self.y + self.height / 2 }
}

public struct ElementObservation: Codable, Equatable, Sendable {
    /// Session-local handle (wink-cua's element index). Valid only for the observation it came from.
    public var handle: Int
    public var role: String
    public var subrole: String?
    public var identifier: String?
    public var title: String?
    public var description: String?
    public var placeholder: String?
    /// Current value. Adapters must leave this nil for secure fields.
    public var value: String?
    public var enabled: Bool
    public var focused: Bool
    public var editable: Bool
    public var secure: Bool
    public var selected: Bool
    public var actions: [String]
    /// Window-relative frame in points.
    public var frame: Rect?
    /// Nearest-first semantic ancestors (windows excluded).
    public var ancestors: [AncestorLocator]
    /// "window", "menu_bar" or "popup".
    public var region: String

    public init(
        handle: Int, role: String, subrole: String? = nil, identifier: String? = nil, title: String? = nil,
        description: String? = nil, placeholder: String? = nil, value: String? = nil, enabled: Bool = true,
        focused: Bool = false, editable: Bool = false, secure: Bool = false, selected: Bool = false,
        actions: [String] = [], frame: Rect? = nil, ancestors: [AncestorLocator] = [], region: String = "window"
    ) {
        self.handle = handle
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.description = description
        self.placeholder = placeholder
        self.value = secure ? nil : value
        self.enabled = enabled
        self.focused = focused
        self.editable = editable
        self.secure = secure
        self.selected = selected
        self.actions = actions
        self.frame = frame
        self.ancestors = ancestors
        self.region = region
    }

    /// Text that names this element when it has no title/description (static text's value).
    public var visibleLabel: String? {
        guard !self.editable, !self.secure else { return nil }
        return self.value
    }

    /// Diagnostic one-liner. Never includes the contents of editable or secure fields.
    public var summary: String {
        var parts = [self.role]
        if let identifier { parts.append("id=\(Redactor.clip(identifier, 60))") }
        if let title { parts.append("\"\(Redactor.clip(title, 80))\"") }
        if let description, description != self.title { parts.append("(\(Redactor.clip(description, 80)))") }
        if let label = self.visibleLabel { parts.append("label=\"\(Redactor.clip(label, 60))\"") }
        if self.editable { parts.append("[editable]") }
        if self.secure { parts.append("[secure]") }
        if !self.enabled { parts.append("[disabled]") }
        if let frame { parts.append("@\(Int(frame.x)),\(Int(frame.y)) \(Int(frame.width))x\(Int(frame.height))") }
        if let a = self.ancestors.first {
            parts.append("in \(a.role) \(a.title ?? a.description ?? a.identifier ?? "")")
        }
        return Redactor.redact(parts.joined(separator: " "))
    }
}

public struct WindowObservation: Codable, Equatable, Sendable {
    public var title: String?
    public var role: String?
    public var subrole: String?
    /// Screen frame in points (top-left origin).
    public var frame: Rect?

    public init(title: String?, role: String? = "AXWindow", subrole: String? = nil, frame: Rect? = nil) {
        self.title = title
        self.role = role
        self.subrole = subrole
        self.frame = frame
    }
}

public struct UIObservation: Codable, Equatable, Sendable {
    public var bundleId: String?
    public var pid: Int32
    public var appName: String
    public var window: WindowObservation?
    public var elements: [ElementObservation]
    public var truncated: Bool

    public init(bundleId: String?, pid: Int32, appName: String, window: WindowObservation?,
                elements: [ElementObservation], truncated: Bool = false) {
        self.bundleId = bundleId
        self.pid = pid
        self.appName = appName
        self.window = window
        self.elements = elements
        self.truncated = truncated
    }
}
