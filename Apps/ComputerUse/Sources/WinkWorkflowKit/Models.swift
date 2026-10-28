import Foundation

// The persisted workflow DSL. Everything here is plain Codable data: no AppKit/AX objects, no session
// element indices, no executable code. Field names are snake_case in JSON.

public enum WorkflowStatus: String, Codable, Sendable, CaseIterable {
    case draft, validated, published, disabled
}

public enum WorkflowEffect: String, Codable, Sendable, CaseIterable {
    case read, write, destructive

    var rank: Int {
        switch self {
        case .read: 0
        case .write: 1
        case .destructive: 2
        }
    }
}

/// The deliberately small action vocabulary. Anything else is rejected with UNSUPPORTED_ACTION.
public enum StepAction: String, Codable, Sendable, CaseIterable {
    case openApp = "open_app"
    case selectWindow = "select_window"
    case click
    case typeText = "type_text"
    case paste
    case setValue = "set_value"
    case pressKey = "press_key"
    case performAction = "perform_action"
    case scroll
    case drag
    case waitFor = "wait_for"
    case assert

    /// Actions that may change app or user data. A failure after one of these was sent is "uncertain".
    public var isMutating: Bool {
        switch self {
        case .click, .typeText, .paste, .setValue, .pressKey, .performAction, .drag: true
        case .openApp, .selectWindow, .scroll, .waitFor, .assert: false
        }
    }

    /// Actions that send input to the app at all.
    public var dispatches: Bool {
        switch self {
        case .waitFor, .assert, .selectWindow: false
        default: true
        }
    }

    var requiresTarget: Bool { self == .setValue || self == .performAction || self == .drag || self == .click }
    var takesTarget: Bool { self.requiresTarget || self == .typeText || self == .paste || self == .scroll }
    var requiresValue: Bool { self == .typeText || self == .paste || self == .setValue }
}

/// A window-relative point in points (origin at the window's top-left). Only ever used as an explicitly
/// authorized, fragile fallback.
public struct RelativePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// A semantic ancestor used as context ("the Delete button inside the toolbar").
public struct AncestorLocator: Codable, Equatable, Sendable {
    public var role: String
    public var identifier: String?
    public var title: String?
    public var description: String?

    public init(role: String, identifier: String? = nil, title: String? = nil, description: String? = nil) {
        self.role = role
        self.identifier = identifier
        self.title = title
        self.description = description
    }

    public var hasSemantics: Bool { self.identifier != nil || self.title != nil || self.description != nil }
}

public struct WindowMatcher: Codable, Equatable, Sendable {
    /// Exact window title (templates allowed).
    public var title: String?
    /// Case-insensitive substring of the window title (templates allowed).
    public var titleContains: String?
    public var role: String?
    public var subrole: String?

    public init(title: String? = nil, titleContains: String? = nil, role: String? = nil, subrole: String? = nil) {
        self.title = title
        self.titleContains = titleContains
        self.role = role
        self.subrole = subrole
    }

    enum CodingKeys: String, CodingKey {
        case title, role, subrole
        case titleContains = "title_contains"
    }
}

/// How a step finds its element at run time. Every string field except `role`/`subrole` may contain
/// `${input}` templates. Never contains a session element index.
public struct ElementLocator: Codable, Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    public var identifier: String?
    public var title: String?
    public var description: String?
    public var placeholder: String?
    /// Visible text of a non-editable element (AXValue of a static text). Never a field's contents.
    public var label: String?
    /// Nearest-first semantic ancestors; each listed one must appear, in order, above the element.
    public var ancestors: [AncestorLocator]?
    /// Restrict the match to a window.
    public var window: WindowMatcher?
    /// Window-relative fallback point; only used with allow_coordinate_fallback on the step and the run.
    public var point: RelativePoint?

    public init(
        role: String? = nil, subrole: String? = nil, identifier: String? = nil, title: String? = nil,
        description: String? = nil, placeholder: String? = nil, label: String? = nil,
        ancestors: [AncestorLocator]? = nil, window: WindowMatcher? = nil, point: RelativePoint? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.description = description
        self.placeholder = placeholder
        self.label = label
        self.ancestors = ancestors
        self.window = window
        self.point = point
    }

    public var hasNameFields: Bool {
        self.title != nil || self.description != nil || self.placeholder != nil || self.label != nil
    }

    public var hasSemantics: Bool { self.identifier != nil || self.hasNameFields }

    /// Readable one-liner for diagnostics.
    public var summary: String {
        var parts = [self.role ?? "any"]
        if let identifier { parts.append("id=\(identifier)") }
        if let title { parts.append("\"\(title)\"") }
        if let description { parts.append("(\(description))") }
        if let placeholder { parts.append("placeholder=\"\(placeholder)\"") }
        if let label { parts.append("label=\"\(label)\"") }
        if let ancestors, !ancestors.isEmpty {
            parts.append("in " + ancestors.map { $0.title ?? $0.description ?? $0.identifier ?? $0.role }
                .joined(separator: " < "))
        }
        if self.point != nil, !self.hasSemantics { parts.append("@point") }
        return parts.joined(separator: " ")
    }

    var templatedStrings: [String] {
        [self.identifier, self.title, self.description, self.placeholder, self.label,
         self.window?.title, self.window?.titleContains].compactMap { $0 }
            + (self.ancestors ?? []).flatMap { [$0.identifier, $0.title, $0.description].compactMap { $0 } }
    }

    func mapStrings(_ transform: (String) throws -> String) rethrows -> ElementLocator {
        var copy = self
        copy.identifier = try self.identifier.map(transform)
        copy.title = try self.title.map(transform)
        copy.description = try self.description.map(transform)
        copy.placeholder = try self.placeholder.map(transform)
        copy.label = try self.label.map(transform)
        copy.ancestors = try self.ancestors?.map { a in
            AncestorLocator(role: a.role, identifier: try a.identifier.map(transform),
                            title: try a.title.map(transform), description: try a.description.map(transform))
        }
        if var w = self.window {
            w.title = try w.title.map(transform)
            w.titleContains = try w.titleContains.map(transform)
            copy.window = w
        }
        return copy
    }
}

public enum ConditionKind: String, Codable, Sendable, CaseIterable {
    case elementExists = "element_exists"
    case elementAbsent = "element_absent"
    case valueEquals = "value_equals"
    case valueContains = "value_contains"
    case windowTitleContains = "window_title_contains"
    case elementEnabled = "element_enabled"
}

/// A UI predicate evaluated against a fresh observation. `kind` is kept as a string so unknown kinds can
/// be reported precisely instead of failing the whole decode.
public struct Condition: Codable, Equatable, Sendable {
    public var kind: String
    public var target: ElementLocator?
    /// Expected value (templates allowed) for value_* and window_title_contains.
    public var value: String?
    /// Optional bundle id when the condition is about another app than the step's.
    public var app: String?

    public init(kind: ConditionKind, target: ElementLocator? = nil, value: String? = nil, app: String? = nil) {
        self.kind = kind.rawValue
        self.target = target
        self.value = value
        self.app = app
    }

    public var parsedKind: ConditionKind? { ConditionKind(rawValue: self.kind) }
}

public struct WorkflowStep: Codable, Equatable, Sendable {
    public var id: String
    /// Kept as a string so unsupported actions produce UNSUPPORTED_ACTION instead of a decode failure.
    public var action: String
    /// Bundle id for this step (default: the workflow's first target bundle id).
    public var app: String?
    public var target: ElementLocator?
    public var toTarget: ElementLocator?
    /// Text for type_text / paste / set_value. Templates: `${name}`; `$${` is a literal `${`.
    public var value: String?
    public var key: String?
    public var axAction: String?
    public var direction: String?
    public var pages: Double?
    public var mouseButton: String?
    public var clickCount: Int?
    public var window: WindowMatcher?
    public var condition: Condition?
    public var preconditions: [Condition]?
    public var postconditions: [Condition]?
    public var timeoutMs: Int?
    public var foreground: Bool?
    public var allowCoordinateFallback: Bool?
    public var note: String?

    public init(id: String, action: StepAction) {
        self.id = id
        self.action = action.rawValue
    }

    public var kind: StepAction? { StepAction(rawValue: self.action) }

    enum CodingKeys: String, CodingKey {
        case id, action, app, target, value, key, direction, pages, window, condition, preconditions,
             postconditions, foreground, note
        case toTarget = "to_target"
        case axAction = "ax_action"
        case mouseButton = "mouse_button"
        case clickCount = "click_count"
        case timeoutMs = "timeout_ms"
        case allowCoordinateFallback = "allow_coordinate_fallback"
    }
}

public enum InputType: String, Codable, Sendable, CaseIterable {
    case string, number, integer, boolean
}

public struct InputSpec: Codable, Equatable, Sendable {
    public var type: String
    public var description: String?
    public var required: Bool?
    public var defaultValue: String?
    public var allowed: [String]?
    /// Secret inputs are never echoed in results, recordings or diagnostics and may fill secure fields.
    public var secret: Bool?
    public var maxLength: Int?

    public init(type: InputType = .string, description: String? = nil, required: Bool? = nil,
                defaultValue: String? = nil, secret: Bool? = nil) {
        self.type = type.rawValue
        self.description = description
        self.required = required
        self.defaultValue = defaultValue
        self.secret = secret
    }

    enum CodingKeys: String, CodingKey {
        case type, description, required, secret
        case defaultValue = "default"
        case allowed = "enum"
        case maxLength = "max_length"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decodeIfPresent(String.self, forKey: .type) ?? "string"
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.required = try c.decodeIfPresent(Bool.self, forKey: .required)
        self.secret = try c.decodeIfPresent(Bool.self, forKey: .secret)
        self.maxLength = try c.decodeIfPresent(Int.self, forKey: .maxLength)
        self.allowed = try c.decodeIfPresent([String].self, forKey: .allowed)
        // Defaults may be written as JSON scalars of the input's type; keep them as text.
        if let s = try? c.decodeIfPresent(String.self, forKey: .defaultValue) {
            self.defaultValue = s
        } else if let b = try? c.decodeIfPresent(Bool.self, forKey: .defaultValue) {
            self.defaultValue = b ? "true" : "false"
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .defaultValue) {
            self.defaultValue = d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        } else {
            self.defaultValue = nil
        }
    }

    public var parsedType: InputType? { InputType(rawValue: self.type) }
    public var isRequired: Bool { self.required ?? (self.defaultValue == nil) }
    public var isSecret: Bool { self.secret ?? false }
}

public struct WorkflowTarget: Codable, Equatable, Sendable {
    public var bundleIds: [String]
    public var windows: [WindowMatcher]?

    public init(bundleIds: [String], windows: [WindowMatcher]? = nil) {
        self.bundleIds = bundleIds
        self.windows = windows
    }

    enum CodingKeys: String, CodingKey {
        case windows
        case bundleIds = "bundle_ids"
    }
}

public struct Provenance: Codable, Equatable, Sendable {
    public var source: String
    public var recordingId: String?
    public var notes: String?

    public init(source: String, recordingId: String? = nil, notes: String? = nil) {
        self.source = source
        self.recordingId = recordingId
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case source, notes
        case recordingId = "recording_id"
    }
}

public struct Workflow: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var revision: Int
    public var name: String
    public var description: String?
    public var status: WorkflowStatus
    public var effect: WorkflowEffect
    /// Descriptive constraint, never a credential: a run must still be given allow_foreground explicitly.
    public var requiresForeground: Bool
    public var target: WorkflowTarget
    public var inputs: [String: InputSpec]
    public var steps: [WorkflowStep]
    /// Named values read from the UI after the last step (value, else title, else description).
    public var outputs: [String: ElementLocator]?
    public var provenance: Provenance?
    public var createdAt: String?
    public var updatedAt: String?

    public init(id: String, name: String, bundleIds: [String], steps: [WorkflowStep] = [],
                inputs: [String: InputSpec] = [:], effect: WorkflowEffect = .write) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.revision = 0
        self.name = name
        self.status = .draft
        self.effect = effect
        self.requiresForeground = false
        self.target = WorkflowTarget(bundleIds: bundleIds)
        self.inputs = inputs
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey {
        case id, revision, name, description, status, effect, target, inputs, steps, outputs, provenance
        case schemaVersion = "schema_version"
        case requiresForeground = "requires_foreground"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        self.id = try c.decode(String.self, forKey: .id)
        self.revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? self.id
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.status = try c.decodeIfPresent(WorkflowStatus.self, forKey: .status) ?? .draft
        self.effect = try c.decodeIfPresent(WorkflowEffect.self, forKey: .effect) ?? .write
        self.requiresForeground = try c.decodeIfPresent(Bool.self, forKey: .requiresForeground) ?? false
        self.target = try c.decode(WorkflowTarget.self, forKey: .target)
        self.inputs = try c.decodeIfPresent([String: InputSpec].self, forKey: .inputs) ?? [:]
        self.steps = try c.decode([WorkflowStep].self, forKey: .steps)
        self.outputs = try c.decodeIfPresent([String: ElementLocator].self, forKey: .outputs)
        self.provenance = try c.decodeIfPresent(Provenance.self, forKey: .provenance)
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    /// Whether any step or postcondition verifies an outcome (required before publishing).
    public var hasVerification: Bool {
        self.steps.contains { step in
            step.kind == .waitFor || step.kind == .assert || !(step.postconditions ?? []).isEmpty
        }
    }

    public var maxStepEffect: WorkflowEffect {
        self.steps.contains { $0.kind?.isMutating == true } ? .write : .read
    }
}
