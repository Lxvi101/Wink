import Foundation

public struct ValidationIssue: Codable, Equatable, Sendable {
    public var code: WorkflowErrorCode
    public var path: String
    public var message: String

    public init(code: WorkflowErrorCode, path: String, message: String) {
        self.code = code
        self.path = path
        self.message = message
    }
}

public struct ValidationReport: Codable, Sendable {
    public var valid: Bool
    public var errors: [ValidationIssue]
    public var warnings: [String]
}

/// Static checks. A workflow that fails these never runs and is never published.
public enum WorkflowValidator {
    public static let maxSteps = 200
    public static let maxInputs = 32
    public static let maxString = 4096
    public static let maxFileBytes = 512 * 1024
    static let knownDirections: Set<String> = ["up", "down", "left", "right"]
    static let knownButtons: Set<String> = ["left", "right", "middle"]

    public static func validate(_ wf: Workflow) -> ValidationReport {
        var errors: [ValidationIssue] = []
        var warnings: [String] = []
        func fail(_ code: WorkflowErrorCode, _ path: String, _ message: String) {
            errors.append(ValidationIssue(code: code, path: path, message: message))
        }
        func fail(_ path: String, _ message: String) { fail(.schemaInvalid, path, message) }

        if wf.schemaVersion != Workflow.currentSchemaVersion {
            fail("schema_version", "unsupported schema_version \(wf.schemaVersion) (supported: \(Workflow.currentSchemaVersion))")
        }
        if !IDs.isSafe(wf.id) { fail("id", "id must match ^[a-z0-9][a-z0-9_-]{0,63}$") }
        if wf.name.isEmpty || wf.name.count > 200 { fail("name", "name must be 1-200 characters") }
        if wf.target.bundleIds.isEmpty { fail("target.bundle_ids", "at least one bundle id is required") }
        for (i, b) in wf.target.bundleIds.enumerated() where !self.isBundleID(b) {
            fail("target.bundle_ids[\(i)]", "'\(Redactor.clip(b, 60))' is not a bundle id")
        }
        if wf.steps.isEmpty { fail("steps", "a workflow needs at least one step") }
        if wf.steps.count > self.maxSteps { fail("steps", "at most \(self.maxSteps) steps") }
        if wf.inputs.count > self.maxInputs { fail("inputs", "at most \(self.maxInputs) inputs") }

        for (name, spec) in wf.inputs {
            let path = "inputs.\(name)"
            if (try? Template.references(in: "${\(name)}")) != [name] { fail(path, "invalid input name") }
            guard let type = spec.parsedType else {
                fail(path + ".type", "unknown input type '\(spec.type)' (string, number, integer, boolean)")
                continue
            }
            if let d = spec.defaultValue, InputBinder.check(d, type: type, spec: spec) != nil {
                fail(path + ".default", "default does not match type \(type.rawValue)")
            }
        }

        var seen = Set<String>()
        var referenced = Set<String>()
        func checkTemplate(_ text: String?, _ path: String) {
            guard let text else { return }
            if text.count > self.maxString { fail(path, "longer than \(self.maxString) characters") }
            do {
                for name in try Template.references(in: text) {
                    referenced.insert(name)
                    if wf.inputs[name] == nil { fail(.invalidInput, path, "references undeclared input ${\(name)}") }
                }
            } catch {
                fail(path, "\(error)")
            }
        }
        func checkLocator(_ l: ElementLocator?, _ path: String, required: Bool) {
            guard let l else {
                if required { fail(path, "a target is required for this action") }
                return
            }
            if !l.hasSemantics, l.role == nil, l.point == nil {
                fail(path, "target needs at least a role, identifier, name or (fallback) point")
            }
            l.templatedStrings.enumerated().forEach { checkTemplate($0.element, "\(path).field\($0.offset)") }
        }
        func checkCondition(_ c: Condition, _ path: String) {
            guard let kind = c.parsedKind else {
                fail(.unsupportedAction, path + ".kind",
                     "unsupported condition '\(c.kind)' (\(ConditionKind.allCases.map(\.rawValue).joined(separator: ", ")))")
                return
            }
            switch kind {
            case .windowTitleContains:
                if c.value == nil { fail(path + ".value", "value is required") }
            case .valueEquals, .valueContains:
                if c.value == nil { fail(path + ".value", "value is required") }
                checkLocator(c.target, path + ".target", required: true)
            case .elementExists, .elementAbsent, .elementEnabled:
                checkLocator(c.target, path + ".target", required: true)
            }
            if let target = c.target, target.point != nil, !target.hasSemantics {
                fail(path + ".target", "conditions cannot use coordinate-only targets")
            }
            checkTemplate(c.value, path + ".value")
            if let app = c.app, !wf.target.bundleIds.contains(app) {
                fail(.wrongApplication, path + ".app", "'\(app)' is not in target.bundle_ids")
            }
        }

        for (i, step) in wf.steps.enumerated() {
            let path = "steps[\(i)]"
            if !IDs.isSafe(step.id) { fail(path + ".id", "step id must match ^[a-z0-9][a-z0-9_-]{0,63}$") }
            if !seen.insert(step.id).inserted { fail(path + ".id", "duplicate step id '\(step.id)'") }
            guard let kind = step.kind else {
                fail(.unsupportedAction, path + ".action",
                     "unsupported action '\(Redactor.clip(step.action, 40))' (supported: \(StepAction.allCases.map(\.rawValue).joined(separator: ", ")))")
                continue
            }
            if let app = step.app, !wf.target.bundleIds.contains(app) {
                fail(.wrongApplication, path + ".app", "'\(app)' is not in target.bundle_ids")
            }
            if kind.requiresTarget || step.target != nil {
                checkLocator(step.target, path + ".target", required: kind.requiresTarget)
            }
            if step.target != nil, !kind.takesTarget, kind != .waitFor, kind != .assert {
                fail(path + ".target", "\(kind.rawValue) does not take a target")
            }
            if let t = step.target, t.point != nil, !t.hasSemantics, step.allowCoordinateFallback != true {
                fail(.permissionDenied, path + ".target.point",
                     "a coordinate-only target needs allow_coordinate_fallback=true on the step")
            }
            if kind.requiresValue {
                if step.value == nil { fail(path + ".value", "value is required for \(kind.rawValue)") }
                checkTemplate(step.value, path + ".value")
            }
            switch kind {
            case .pressKey:
                if (step.key ?? "").trimmingCharacters(in: .whitespaces).isEmpty { fail(path + ".key", "key is required") }
                checkTemplate(step.key, path + ".key")
            case .performAction:
                if (step.axAction ?? "").isEmpty { fail(path + ".ax_action", "ax_action is required") }
            case .drag:
                checkLocator(step.toTarget, path + ".to_target", required: true)
            case .scroll:
                if !self.knownDirections.contains(step.direction ?? "") {
                    fail(path + ".direction", "direction must be up, down, left or right")
                }
                if let pages = step.pages, !(0.1...20).contains(pages) { fail(path + ".pages", "pages must be 0.1-20") }
            case .waitFor, .assert:
                guard let condition = step.condition else {
                    fail(path + ".condition", "\(kind.rawValue) needs a condition")
                    break
                }
                checkCondition(condition, path + ".condition")
            case .selectWindow:
                if step.window == nil { fail(path + ".window", "select_window needs a window matcher") }
                checkTemplate(step.window?.title, path + ".window.title")
                checkTemplate(step.window?.titleContains, path + ".window.title_contains")
            case .click:
                if let b = step.mouseButton, !self.knownButtons.contains(b) { fail(path + ".mouse_button", "left, right or middle") }
                if let n = step.clickCount, !(1...3).contains(n) { fail(path + ".click_count", "1-3") }
            case .openApp, .typeText, .paste, .setValue:
                break
            }
            for (j, c) in (step.preconditions ?? []).enumerated() { checkCondition(c, "\(path).preconditions[\(j)]") }
            for (j, c) in (step.postconditions ?? []).enumerated() { checkCondition(c, "\(path).postconditions[\(j)]") }
            if let t = step.timeoutMs, !(0...120_000).contains(t) { fail(path + ".timeout_ms", "timeout_ms must be 0-120000") }
            if step.foreground == true, !wf.requiresForeground {
                fail(.permissionDenied, path + ".foreground", "foreground steps need requires_foreground=true on the workflow")
            }
            if step.value != nil, !kind.requiresValue { warnings.append("\(path): value is ignored for \(kind.rawValue)") }
        }
        for (name, spec) in (wf.outputs ?? [:]) {
            if !IDs.isSafe(name.lowercased()) { fail("outputs.\(name)", "invalid output name") }
            checkLocator(spec, "outputs.\(name)", required: true)
        }
        if wf.effect.rank < wf.maxStepEffect.rank {
            fail("effect", "effect '\(wf.effect.rawValue)' understates the steps (which can write)")
        }
        for name in wf.inputs.keys where !referenced.contains(name) {
            warnings.append("input '\(name)' is declared but never used")
        }
        if !wf.hasVerification {
            warnings.append("no wait_for/assert step or postcondition: success would only mean the actions were sent")
        }
        return ValidationReport(valid: errors.isEmpty, errors: errors, warnings: warnings)
    }

    static func isBundleID(_ s: String) -> Bool {
        s.count <= 255 && s.contains(".")
            && s.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]*$"#, options: .regularExpression) != nil
    }

    /// Decode + validate raw JSON bytes from an untrusted source (file or tool argument).
    public static func decode(_ data: Data) throws -> Workflow {
        guard data.count <= self.maxFileBytes else {
            throw WorkflowError(.schemaInvalid, "workflow is larger than \(self.maxFileBytes / 1024) KB")
        }
        do {
            return try WorkflowJSON.decode(Workflow.self, from: data)
        } catch {
            throw WorkflowError(.schemaInvalid, WorkflowJSON.describe(error))
        }
    }
}

/// Converts runtime inputs (JSON values) into the strings templates substitute, with type checks.
public enum InputBinder {
    public static func bind(_ raw: [String: Any], spec: [String: InputSpec]) throws -> [String: String] {
        for key in raw.keys where spec[key] == nil {
            throw WorkflowError(.invalidInput, "unknown input '\(Redactor.clip(key, 40))'")
        }
        var out: [String: String] = [:]
        for (name, s) in spec {
            guard let type = s.parsedType else { throw WorkflowError(.schemaInvalid, "input '\(name)' has an unknown type") }
            let text: String
            if let value = raw[name], !(value is NSNull) {
                guard let converted = self.text(value, type: type) else {
                    throw WorkflowError(.invalidInput, "input '\(name)' must be a \(type.rawValue)")
                }
                text = converted
            } else if let d = s.defaultValue {
                text = d
            } else if s.isRequired {
                throw WorkflowError(.invalidInput, "missing required input '\(name)'")
            } else {
                text = ""
            }
            if let problem = self.check(text, type: type, spec: s) {
                throw WorkflowError(.invalidInput, "input '\(name)': \(problem)")
            }
            out[name] = text
        }
        return out
    }

    static func text(_ value: Any, type: InputType) -> String? {
        switch (type, value) {
        case let (.string, s as String): return s
        case let (.boolean, n as NSNumber) where CFGetTypeID(n) == CFBooleanGetTypeID(): return n.boolValue ? "true" : "false"
        case let (.boolean, s as String) where s == "true" || s == "false": return s
        case let (.number, n as NSNumber) where CFGetTypeID(n) != CFBooleanGetTypeID():
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case let (.integer, n as NSNumber) where CFGetTypeID(n) != CFBooleanGetTypeID():
            return n.doubleValue == n.doubleValue.rounded() ? String(n.int64Value) : nil
        case let (.number, s as String): return Double(s) != nil ? s : nil
        case let (.integer, s as String): return Int64(s) != nil ? s : nil
        default: return nil
        }
    }

    static func check(_ text: String, type: InputType, spec: InputSpec) -> String? {
        let limit = min(spec.maxLength ?? 10_000, 100_000)
        if text.count > limit { return "longer than \(limit) characters" }
        switch type {
        case .number where Double(text) == nil: return "not a number"
        case .integer where Int64(text) == nil: return "not an integer"
        case .boolean where text != "true" && text != "false": return "not a boolean"
        default: break
        }
        if let allowed = spec.allowed, !allowed.contains(text) { return "must be one of \(allowed.joined(separator: ", "))" }
        return nil
    }
}
