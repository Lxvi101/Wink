import Foundation

public struct ParameterSpec: Codable, Sendable {
    /// The literal used during the recording; every exact occurrence becomes `${name}`.
    public var example: String
    public var type: String?
    public var description: String?
    public var secret: Bool?
}

public struct CompileOptions: Codable, Sendable {
    public var id: String?
    public var name: String?
    public var description: String?
    public var parameters: [String: ParameterSpec]?
    /// Recorded action sequence numbers to leave out (exploration, mistakes).
    public var exclude: [Int]?
    /// Extra steps (typically wait_for/assert) appended after the recorded ones.
    public var appendSteps: [WorkflowStep]?
    /// Append the strongest suggested verification after the last mutating step.
    public var autoVerify: Bool?
    public var effect: WorkflowEffect?
    public var outputs: [String: ElementLocator]?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case id, name, description, parameters, exclude, effect, outputs
        case appendSteps = "append_steps"
        case autoVerify = "auto_verify"
    }
}

public struct ParameterCandidate: Codable, Sendable {
    public var stepId: String
    public var field: String
    public var example: String
    public var suggestedName: String

    enum CodingKeys: String, CodingKey {
        case field, example
        case stepId = "step_id"
        case suggestedName = "suggested_name"
    }
}

public struct SuggestedVerification: Codable, Sendable {
    public var afterStepId: String
    public var condition: Condition

    enum CodingKeys: String, CodingKey {
        case condition
        case afterStepId = "after_step_id"
    }
}

public struct CompileReport: Codable, Sendable {
    public var workflow: Workflow
    public var warnings: [String]
    public var parameterCandidates: [ParameterCandidate]
    public var suggestedVerifications: [SuggestedVerification]
    public var skipped: [String]

    enum CodingKeys: String, CodingKey {
        case workflow, warnings, skipped
        case parameterCandidates = "parameter_candidates"
        case suggestedVerifications = "suggested_verifications"
    }
}

/// Turns a recording of real agent actions into a draft workflow. The agent supplies the judgement
/// (which literals are inputs, what proves success); the compiler keeps the result explicit and checkable.
public enum WorkflowCompiler {
    public static func compile(_ recording: Recording, options: CompileOptions) throws -> CompileReport {
        var warnings: [String] = []
        var skipped: [String] = []
        let excluded = Set(options.exclude ?? [])
        var steps: [WorkflowStep] = []
        var bundles: [String] = []
        var opened = Set<String>()
        var lastWindowSelector: [String: String] = [:]
        var candidates: [ParameterCandidate] = []
        var suggestions: [SuggestedVerification] = []
        var inputs: [String: InputSpec] = [:]
        var usedIds = Set<String>()

        func stepId(_ base: String) -> String {
            var id = String(IDs.slug(base).prefix(40))
            if id.isEmpty { id = "step" }
            var n = 1
            var candidate = "s\(steps.count + 1)_\(id)"
            while usedIds.contains(candidate) { n += 1; candidate = "s\(steps.count + 1)_\(id)_\(n)" }
            usedIds.insert(candidate)
            return candidate
        }

        for action in recording.actions {
            if excluded.contains(action.seq) { skipped.append("#\(action.seq) \(action.action): excluded"); continue }
            guard let kind = StepAction(rawValue: action.action) else {
                skipped.append("#\(action.seq) \(action.tool): unsupported action")
                continue
            }
            if action.status != "ok", !action.dispatched {
                skipped.append("#\(action.seq) \(action.action): failed without being sent")
                continue
            }
            if action.status != "ok" {
                warnings.append("#\(action.seq) \(action.action) failed after it may have been sent; review it")
            }
            guard let bundle = action.bundleId else {
                skipped.append("#\(action.seq) \(action.action): app has no bundle id")
                continue
            }
            if !bundles.contains(bundle) { bundles.append(bundle) }
            if !opened.contains(bundle) {
                opened.insert(bundle)
                var open = WorkflowStep(id: stepId("open \(bundle.split(separator: ".").last ?? "app")"), action: .openApp)
                open.app = bundle
                steps.append(open)
            }

            if kind == .selectWindow {
                guard let selector = action.windowSelector, !selector.isEmpty else { continue }
                if lastWindowSelector[bundle] == selector { continue } // duplicate observation
                lastWindowSelector[bundle] = selector
                var step = WorkflowStep(id: stepId("select window"), action: .selectWindow)
                step.app = bundle
                step.window = Int(selector) == nil ? WindowMatcher(titleContains: Template.escape(selector)) : nil
                if step.window == nil {
                    warnings.append("#\(action.seq): window selected by index \(selector); add a title matcher")
                    continue
                }
                steps.append(step)
                continue
            }

            var step = WorkflowStep(id: stepId("\(kind.rawValue) \(action.target?.title ?? action.target?.description ?? action.target?.identifier ?? "")"),
                                    action: kind)
            step.app = bundle == bundles.first ? nil : bundle
            step.target = action.target.map(self.escape)
            step.toTarget = action.toTarget.map(self.escape)
            step.key = action.key
            step.axAction = action.axAction
            step.direction = action.direction
            step.pages = action.pages
            step.mouseButton = action.mouseButton == "left" ? nil : action.mouseButton
            step.clickCount = action.clickCount == 1 ? nil : action.clickCount
            if action.foreground { step.foreground = true }

            if action.target == nil, let point = action.point, kind.takesTarget {
                step.target = ElementLocator(point: point)
                step.allowCoordinateFallback = true
                warnings.append("\(step.id): recorded as a coordinate click with no accessible element; it only runs with allow_coordinate_fallback and is fragile")
            } else if kind.requiresTarget, action.target == nil {
                skipped.append("#\(action.seq) \(kind.rawValue): no semantic target was captured")
                continue
            }

            if let text = action.text {
                if let literal = text.literal {
                    step.value = Template.escape(literal)
                    candidates.append(ParameterCandidate(stepId: step.id, field: "value", example: Redactor.clip(literal, 80),
                                                         suggestedName: self.suggestName(for: action, existing: inputs)))
                } else {
                    // The text was not recorded: it must come from an input.
                    let name = self.suggestName(for: action, existing: inputs)
                    inputs[name] = InputSpec(type: .string, description: "Text for \(step.id) (not recorded: \(text.reason ?? "redacted"))",
                                             secret: action.targetSecure || text.reason == "looks_secret" ? true : nil)
                    step.value = "${\(name)}"
                    warnings.append("\(step.id): the recorded text was redacted (\(text.reason ?? "redacted")); it is now input '\(name)'")
                }
            }
            steps.append(step)

            if kind.isMutating, let evidence = action.evidence {
                if let s = self.suggestion(from: evidence, after: step.id) { suggestions.append(s) }
            }
        }

        if steps.allSatisfy({ $0.kind == .openApp }) {
            throw WorkflowError(.schemaInvalid, "the recording has no usable actions (\(skipped.count) skipped)")
        }

        // Parameterize: replace example literals with input references.
        for (name, p) in (options.parameters ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard (try? Template.references(in: "${\(name)}")) == [name] else {
                throw WorkflowError(.invalidArgument, "invalid parameter name '\(name)'")
            }
            guard !p.example.isEmpty else { throw WorkflowError(.invalidArgument, "parameter '\(name)' needs an example") }
            let escaped = Template.escape(p.example)
            var replaced = 0
            for i in steps.indices {
                if let v = steps[i].value, v.contains(escaped) {
                    replaced += v.components(separatedBy: escaped).count - 1
                    steps[i].value = v.replacingOccurrences(of: escaped, with: "${\(name)}")
                }
                func swap(_ l: ElementLocator?) -> ElementLocator? {
                    l?.mapStrings { s in
                        if s == escaped { replaced += 1; return "${\(name)}" }
                        return s
                    }
                }
                steps[i].target = swap(steps[i].target)
                steps[i].toTarget = swap(steps[i].toTarget)
            }
            if replaced == 0 { warnings.append("parameter '\(name)': example not found in any recorded value or target") }
            let type = p.type.flatMap(InputType.init(rawValue:)) ?? .string
            inputs[name] = InputSpec(type: type, description: p.description, secret: p.secret)
            candidates.removeAll { c in steps.first { $0.id == c.stepId }?.value?.contains("${\(name)}") == true }
            for i in suggestions.indices {
                suggestions[i].condition.value = suggestions[i].condition.value?
                    .replacingOccurrences(of: escaped, with: "${\(name)}")
                suggestions[i].condition.target = suggestions[i].condition.target?.mapStrings { $0 == escaped ? "${\(name)}" : $0 }
            }
        }

        for var extra in options.appendSteps ?? [] {
            if usedIds.contains(extra.id) { extra.id = stepId(extra.id) } else { usedIds.insert(extra.id) }
            steps.append(extra)
        }
        if options.autoVerify == true, let last = suggestions.last {
            var verify = WorkflowStep(id: stepId("verify"), action: .waitFor)
            verify.condition = last.condition
            verify.timeoutMs = 5000
            steps.append(verify)
            warnings.append("\(verify.id): verification was suggested from the recording; check it proves the intended outcome")
        }

        let firstName = recording.name ?? options.name ?? "workflow"
        let id = options.id ?? IDs.slug(firstName)
        guard IDs.isSafe(id) else { throw WorkflowError(.invalidArgument, "workflow id must match ^[a-z0-9][a-z0-9_-]{0,63}$") }
        var wf = Workflow(id: id, name: options.name ?? recording.name ?? id, bundleIds: bundles, steps: steps,
                          inputs: inputs)
        wf.description = options.description
        wf.effect = options.effect ?? wf.maxStepEffect
        wf.requiresForeground = steps.contains { $0.foreground == true }
        wf.outputs = options.outputs
        wf.provenance = Provenance(source: "recording", recordingId: recording.id)
        if recording.droppedActions > 0 {
            warnings.append("the recording dropped \(recording.droppedActions) actions over the \(WorkflowRecorder.maxActions) limit")
        }
        if !wf.hasVerification {
            warnings.append("no verification: add a wait_for/assert (append_steps, auto_verify, or edit and workflow_save) before publishing")
        }
        let report = WorkflowValidator.validate(wf)
        warnings += report.errors.map { "invalid: \($0.path): \($0.message)" }
        warnings += report.warnings.filter { !$0.hasPrefix("no wait_for") }
        return CompileReport(workflow: wf, warnings: warnings, parameterCandidates: candidates,
                             suggestedVerifications: suggestions, skipped: skipped)
    }

    /// Recorded locator strings are literals; escape anything that looks like a template.
    static func escape(_ l: ElementLocator) -> ElementLocator { l.mapStrings(Template.escape) }

    static func suggestName(for action: RecordedAction, existing: [String: InputSpec]) -> String {
        let base = IDs.slug(action.target?.placeholder ?? action.target?.title ?? action.target?.description ?? "text")
        let root = base.isEmpty || base.first!.isNumber ? "text" : String(base.prefix(30))
        var name = root
        var n = 2
        while existing[name] != nil { name = "\(root)_\(n)"; n += 1 }
        return name
    }

    /// The strongest evidence first: a named element showing a value (a result, a status line), then a
    /// named element that appeared.
    static func suggestion(from evidence: ActionEvidence, after stepId: String) -> SuggestedVerification? {
        let valued = evidence.samples.filter { $0.value != nil && $0.locator.hasSemantics && $0.locator.label == nil }
        if let sample = valued.first(where: { $0.change == "changed" }) ?? valued.first {
            var locator = self.escape(sample.locator)
            locator.label = nil
            return SuggestedVerification(afterStepId: stepId, condition: Condition(
                kind: .valueEquals, target: locator, value: sample.value.map(Template.escape)))
        }
        if let added = evidence.samples.first(where: { $0.change == "added" && $0.locator.hasSemantics }) {
            return SuggestedVerification(afterStepId: stepId,
                                         condition: Condition(kind: .elementExists, target: self.escape(added.locator)))
        }
        return nil
    }
}
