import Foundation

/// Text an agent typed/pasted/set while recording. Secure-field text and credential-like text is never kept.
public struct RecordedText: Codable, Equatable, Sendable {
    public var literal: String?
    public var redacted: Bool
    /// "secure_field", "looks_secret", "capture_text_off", "too_long"
    public var reason: String?
    public var length: Int

    public init(literal: String?, redacted: Bool, reason: String?, length: Int) {
        self.literal = literal
        self.redacted = redacted
        self.reason = reason
        self.length = length
    }

    /// Applies the recording privacy rules.
    public static func capture(_ text: String, secureTarget: Bool, captureText: Bool) -> RecordedText {
        if secureTarget { return RecordedText(literal: nil, redacted: true, reason: "secure_field", length: text.count) }
        if !captureText { return RecordedText(literal: nil, redacted: true, reason: "capture_text_off", length: text.count) }
        if Redactor.looksSecret(text) { return RecordedText(literal: nil, redacted: true, reason: "looks_secret", length: text.count) }
        if text.count > 4000 { return RecordedText(literal: nil, redacted: true, reason: "too_long", length: text.count) }
        return RecordedText(literal: text, redacted: false, reason: nil, length: text.count)
    }
}

public struct WindowContext: Codable, Equatable, Sendable {
    public var title: String?
    public var role: String?
    public var frame: Rect?

    public init(title: String?, role: String?, frame: Rect?) {
        self.title = title
        self.role = role
        self.frame = frame
    }
}

/// A UI element that appeared or changed after an action: raw material for suggested verifications.
public struct EvidenceElement: Codable, Equatable, Sendable {
    public var change: String // "added" | "changed"
    public var locator: ElementLocator
    /// Value of non-editable, non-secure elements only (e.g. a result label), clipped and redacted.
    public var value: String?

    public init(change: String, locator: ElementLocator, value: String?) {
        self.change = change
        self.locator = locator
        self.value = value
    }
}

public struct ActionEvidence: Codable, Equatable, Sendable {
    public var added: Int
    public var changed: Int
    public var removed: Int
    public var windowTitle: String?
    public var samples: [EvidenceElement]

    public init(added: Int, changed: Int, removed: Int, windowTitle: String?, samples: [EvidenceElement]) {
        self.added = added
        self.changed = changed
        self.removed = removed
        self.windowTitle = windowTitle
        self.samples = samples
    }

    enum CodingKeys: String, CodingKey {
        case added, changed, removed, samples
        case windowTitle = "window_title"
    }

    /// Drops every sample that shows text the recording was not allowed to keep (e.g. a secure field's
    /// value echoed into a label), so redacted input never reaches disk through the evidence.
    public func scrubbing(_ secret: String) -> ActionEvidence {
        guard !secret.isEmpty else { return self }
        var copy = self
        copy.samples = self.samples.filter { sample in
            !(sample.value ?? "").contains(secret) && !sample.locator.templatedStrings.contains { $0.contains(secret) }
        }
        if copy.windowTitle?.contains(secret) == true { copy.windowTitle = nil }
        return copy
    }

    /// Builds evidence from before/after observations of the same app, keeping private content out.
    public static func diff(before: [String: ElementObservation], after: [(key: String, element: ElementObservation)],
                            windowTitle: String?, sampleLimit: Int = 6) -> ActionEvidence {
        var added = 0, changed = 0
        var samples: [EvidenceElement] = []
        let afterKeys = Set(after.map(\.key))
        for (key, element) in after {
            let kind: String
            if let old = before[key] {
                guard old != element.withHandle(old.handle) else { continue }
                changed += 1
                kind = "changed"
            } else {
                added += 1
                kind = "added"
            }
            guard samples.count < sampleLimit, element.region != "menu_bar" else { continue }
            var locator = LocatorBuilder.locator(for: element)
            if kind == "changed" { locator.label = nil } // a changed value is the evidence, not the name
            guard locator.hasSemantics || kind == "added" else { continue }
            let value = element.visibleLabel.flatMap { Redactor.looksSecret($0) ? nil : Redactor.sanitize($0, limit: 120) }
            samples.append(EvidenceElement(change: kind, locator: locator, value: value))
        }
        let removed = before.keys.filter { !afterKeys.contains($0) }.count
        return ActionEvidence(added: added, changed: changed, removed: removed,
                              windowTitle: windowTitle.map { Redactor.sanitize($0, limit: 120) }, samples: samples)
    }
}

extension ElementObservation {
    func withHandle(_ handle: Int) -> ElementObservation {
        var copy = self
        copy.handle = handle
        return copy
    }
}

public struct RecordedAction: Codable, Equatable, Sendable {
    public var seq: Int
    public var tool: String
    /// The workflow step action this maps to.
    public var action: String
    public var bundleId: String?
    public var window: WindowContext?
    public var target: ElementLocator?
    public var toTarget: ElementLocator?
    /// Readable summary of the target at the time (no field contents).
    public var targetSummary: String?
    public var targetSecure: Bool
    /// Window-relative point for coordinate actions without a resolvable element.
    public var point: RelativePoint?
    public var text: RecordedText?
    public var key: String?
    public var axAction: String?
    public var direction: String?
    public var pages: Double?
    public var mouseButton: String?
    public var clickCount: Int?
    public var windowSelector: String?
    public var foreground: Bool
    public var dispatched: Bool
    /// "ok" | "error"
    public var status: String
    public var error: String?
    public var elapsedMs: Int
    /// "observed_change" | "no_change" | "unobserved" | "failed"
    public var outcome: String
    public var evidence: ActionEvidence?
    public var diagnosticId: String?
    public var timestamp: String

    public init(seq: Int, tool: String, action: StepAction, bundleId: String?) {
        self.seq = seq
        self.tool = tool
        self.action = action.rawValue
        self.bundleId = bundleId
        self.targetSecure = false
        self.foreground = false
        self.dispatched = false
        self.status = "ok"
        self.elapsedMs = 0
        self.outcome = "unobserved"
        self.timestamp = WorkflowClock.now()
    }

    enum CodingKeys: String, CodingKey {
        case seq, tool, action, window, target, point, text, key, direction, pages, foreground, dispatched, status,
             error, outcome, evidence, timestamp
        case bundleId = "bundle_id"
        case toTarget = "to_target"
        case targetSummary = "target_summary"
        case targetSecure = "target_secure"
        case axAction = "ax_action"
        case mouseButton = "mouse_button"
        case clickCount = "click_count"
        case windowSelector = "window_selector"
        case elapsedMs = "elapsed_ms"
        case diagnosticId = "diagnostic_id"
    }
}

public struct Recording: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var name: String?
    public var startedAt: String
    public var stoppedAt: String?
    public var captureText: Bool
    /// Only actions on these bundle ids are recorded (empty = all apps).
    public var apps: [String]
    public var actions: [RecordedAction]
    public var droppedActions: Int

    enum CodingKeys: String, CodingKey {
        case id, name, apps, actions
        case schemaVersion = "schema_version"
        case startedAt = "started_at"
        case stoppedAt = "stopped_at"
        case captureText = "capture_text"
        case droppedActions = "dropped_actions"
    }
}

/// In-memory recorder for agent-executed actions. Off by default; when off, `isActive` is a plain bool
/// check and nothing is observed or stored.
public final class WorkflowRecorder: @unchecked Sendable {
    public static let maxActions = 500
    private let lock = NSLock()
    private var current: Recording?

    public init() {}

    public var isActive: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.current != nil
    }

    public var activeId: String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.current?.id
    }

    public func start(name: String?, apps: [String], captureText: Bool) throws -> Recording {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let current { throw WorkflowError(.recordingState, "recording \(current.id) is already active; stop it first") }
        let recording = Recording(
            schemaVersion: 1, id: IDs.make("rec"), name: name.map { Redactor.sanitize($0, limit: 200) },
            startedAt: WorkflowClock.now(), stoppedAt: nil, captureText: captureText, apps: apps, actions: [],
            droppedActions: 0)
        self.current = recording
        return recording
    }

    /// Whether an action on this app should be captured right now.
    public func wants(bundleId: String?) -> (captureText: Bool, seq: Int)? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let current else { return nil }
        if !current.apps.isEmpty, !(bundleId.map(current.apps.contains) ?? false) { return nil }
        return (current.captureText, current.actions.count + current.droppedActions + 1)
    }

    public func append(_ action: RecordedAction) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.current != nil else { return }
        if self.current!.actions.count >= Self.maxActions {
            self.current!.droppedActions += 1
        } else {
            self.current!.actions.append(action)
        }
    }

    public func stop() throws -> Recording {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard var recording = self.current else { throw WorkflowError(.recordingState, "no recording is active") }
        recording.stoppedAt = WorkflowClock.now()
        self.current = nil
        return recording
    }
}
