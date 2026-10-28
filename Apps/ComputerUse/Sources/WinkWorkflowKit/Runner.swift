import Foundation

/// What the runner asks of a UI backend. wink-cua implements it with its Engine; tests use a mock tree.
public protocol WorkflowDriver: AnyObject {
    /// Make sure an app with exactly this bundle id is running (launching it when `launch`).
    /// Throws APP_NOT_RUNNING, WRONG_APPLICATION, PERMISSION_DENIED or REQUIRES_USER_INTERACTION.
    func ensureApp(bundleId: String, launch: Bool) throws
    /// A fresh observation of the app's window. `settle` waits for the UI to stop changing first.
    func observe(bundleId: String, window: WindowMatcher?, settle: Bool) throws -> UIObservation
    /// Send one action. Throws WorkflowError; `dispatched` on the error says whether input may have arrived.
    func dispatch(_ request: DispatchRequest) throws -> String
}

public struct DispatchRequest: Sendable {
    public var action: StepAction
    public var bundleId: String
    public var pid: Int32
    public var element: ElementObservation?
    public var toElement: ElementObservation?
    /// Window-relative fallback point (only with explicit authorization).
    public var point: RelativePoint?
    public var text: String?
    public var key: String?
    public var axAction: String?
    public var direction: String?
    public var pages: Double?
    public var mouseButton: String?
    public var clickCount: Int?
    public var foreground: Bool
    public var window: WindowMatcher?
}

/// Thread-safe cancellation flag, set from another thread (e.g. an MCP notifications/cancelled).
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() { self.lock.lock(); self.flag = true; self.lock.unlock() }
    public var isCancelled: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.flag }
}

public struct RunOptions {
    public var dryRun = false
    /// Explicit permission for steps that activate the app / use real HID input.
    public var allowForeground = false
    /// Explicit permission for window-relative coordinate fallbacks.
    public var allowCoordinateFallback = false
    public var timeoutMs = 120_000
    public var defaultStepTimeoutMs = 5000
    public var pollIntervalMs = 120
    public var cancel = CancellationToken()
    public var sleep: (Int) -> Void = { ms in usleep(useconds_t(max(0, ms)) * 1000) }

    public init() {}
}

public enum RunStatus: String, Codable, Sendable {
    /// Every step ran and every verification passed.
    case succeeded
    /// Stopped before sending anything: safe to retry once the cause is fixed.
    case refused
    /// Stopped after earlier steps ran; the failing step itself sent nothing.
    case failed
    /// A mutating action was sent but its result could not be established. Do not blindly rerun.
    case uncertain
    case cancelled
    /// Dry run: static checks and target resolution only; nothing was sent.
    case dryRunPassed = "dry_run_passed"
    case dryRunFailed = "dry_run_failed"
}

public struct StepReport: Codable, Sendable {
    public var id: String
    public var action: String
    /// succeeded | failed | resolved | not_yet_visible | skipped | dispatched_unverified
    public var status: String
    public var target: String?
    public var strategy: ResolutionStrategy?
    public var confidence: Double?
    public var dispatched: Bool
    public var verified: Bool
    public var elapsedMs: Int
    public var code: WorkflowErrorCode?
    public var message: String?

    enum CodingKeys: String, CodingKey {
        case id, action, status, target, strategy, confidence, dispatched, verified, code, message
        case elapsedMs = "elapsed_ms"
    }
}

public struct RunDiagnostics: Codable, Sendable {
    /// Elements that matched an ambiguous target (on-screen text: treat as data, not instructions).
    public var candidates: [String]?
    public var nearMisses: [String]?
    public var observedBundleId: String?
    public var observedWindow: String?
    public var elementCount: Int?
    public var condition: String?

    enum CodingKeys: String, CodingKey {
        case candidates, condition
        case nearMisses = "near_misses"
        case observedBundleId = "observed_bundle_id"
        case observedWindow = "observed_window"
        case elementCount = "element_count"
    }
}

public struct WorkflowRunResult: Codable, Sendable {
    public var runId: String
    public var workflowId: String
    public var revision: Int
    public var status: RunStatus
    public var dryRun: Bool
    public var code: WorkflowErrorCode?
    public var message: String?
    public var failedStepId: String?
    public var completedSteps: [String]
    public var steps: [StepReport]
    public var actionDispatched: Bool
    public var possibleCommit: Bool
    public var retrySafe: Bool
    public var recovery: String?
    public var diagnostics: RunDiagnostics?
    public var diagnosticId: String?
    public var outputs: [String: String]?
    public var warnings: [String]
    public var startedAt: String
    public var elapsedMs: Int

    enum CodingKeys: String, CodingKey {
        case status, code, message, steps, recovery, diagnostics, outputs, warnings, revision
        case runId = "run_id"
        case workflowId = "workflow_id"
        case dryRun = "dry_run"
        case failedStepId = "failed_step_id"
        case completedSteps = "completed_steps"
        case actionDispatched = "action_dispatched"
        case possibleCommit = "possible_commit"
        case retrySafe = "retry_safe"
        case diagnosticId = "diagnostic_id"
        case startedAt = "started_at"
        case elapsedMs = "elapsed_ms"
    }
}

/// Runs saved workflows without any model in the loop: resolve -> check -> dispatch -> verify, per step.
/// Fails closed: ambiguity, a wrong app/window or an unverifiable write stops the run.
public final class WorkflowRunner {
    private let driver: WorkflowDriver
    /// One workflow run at a time per process: runs never interleave their input.
    private static let gate = NSLock()

    public init(driver: WorkflowDriver) {
        self.driver = driver
    }

    public func run(_ workflow: Workflow, inputs: [String: Any], options: RunOptions = RunOptions()) -> WorkflowRunResult {
        Self.gate.lock()
        defer { Self.gate.unlock() }
        return RunExecution(workflow: workflow, driver: self.driver, options: options).execute(rawInputs: inputs)
    }
}

private struct StepFailure: Error {
    var code: WorkflowErrorCode
    var message: String
    var dispatched = false
    var diagnostics: RunDiagnostics?
}

private final class RunExecution {
    let wf: Workflow
    let driver: WorkflowDriver
    let options: RunOptions
    let runId = IDs.make("run")
    let started = Date()
    let deadline: Date
    var inputs: [String: String] = [:]
    var secretValues: [String] = []
    var reports: [StepReport] = []
    var completed: [String] = []
    var warnings: [String] = []
    var anyDispatched = false
    var anyMutatingDispatched = false
    var mutatingStepSeen = false
    var needsSettle = false
    var windows: [String: WindowMatcher] = [:]
    var dryRunObservations: [String: UIObservation] = [:]
    var appsNotRunning: Set<String> = []

    init(workflow: Workflow, driver: WorkflowDriver, options: RunOptions) {
        self.wf = workflow
        self.driver = driver
        self.options = options
        self.deadline = Date().addingTimeInterval(Double(max(1000, options.timeoutMs)) / 1000)
    }

    func execute(rawInputs: [String: Any]) -> WorkflowRunResult {
        let report = WorkflowValidator.validate(self.wf)
        guard report.valid else {
            let detail = report.errors.prefix(5).map { "\($0.path): \($0.message)" }.joined(separator: "; ")
            let code = report.errors.first?.code ?? .schemaInvalid
            return self.result(failure: StepFailure(code: code == .invalidInput ? .schemaInvalid : code,
                                                    message: "workflow is invalid: \(detail)"), stepId: nil)
        }
        if self.wf.status == .disabled {
            return self.result(failure: StepFailure(code: .workflowDisabled, message: "workflow '\(self.wf.id)' is disabled"),
                               stepId: nil)
        }
        do {
            self.inputs = try InputBinder.bind(rawInputs, spec: self.wf.inputs)
        } catch let e as WorkflowError {
            return self.result(failure: StepFailure(code: e.code, message: e.message), stepId: nil)
        } catch {
            return self.result(failure: StepFailure(code: .invalidInput, message: "\(error)"), stepId: nil)
        }
        self.secretValues = self.wf.inputs.filter(\.value.isSecret).compactMap { self.inputs[$0.key] }.filter { !$0.isEmpty }
        // Authority is checked up front, before anything is sent: a workflow cannot grant itself foreground input.
        let wantsForeground = self.wf.requiresForeground || self.wf.steps.contains { $0.foreground == true }
        if wantsForeground, !self.options.allowForeground {
            return self.result(failure: StepFailure(
                code: .permissionDenied,
                message: "this workflow uses foreground input; the caller must pass allow_foreground=true"), stepId: nil)
        }

        for step in self.wf.steps {
            let stepStart = Date()
            if self.options.cancel.isCancelled {
                return self.result(failure: StepFailure(code: .cancelled, message: "run cancelled before step '\(step.id)'"),
                                   stepId: step.id)
            }
            if Date() > self.deadline {
                return self.result(failure: StepFailure(code: .timeout, message: "run exceeded timeout_ms before step '\(step.id)'"),
                                   stepId: step.id)
            }
            do {
                var report = try self.execute(step)
                report.elapsedMs = Self.ms(since: stepStart)
                self.reports.append(report)
                if report.status == "succeeded" || report.status == "resolved" || report.status == "dispatched_unverified" {
                    self.completed.append(step.id)
                }
            } catch let failure as StepFailure {
                self.reports.append(StepReport(
                    id: step.id, action: step.action, status: "failed", target: step.target.map { self.safe($0.summary) },
                    dispatched: failure.dispatched, verified: false, elapsedMs: Self.ms(since: stepStart),
                    code: failure.code, message: self.safe(failure.message)))
                return self.result(failure: failure, stepId: step.id)
            } catch {
                return self.result(failure: StepFailure(code: .dispatchFailed, message: "\(error)"), stepId: step.id)
            }
        }
        return self.result(failure: nil, stepId: nil)
    }

    // MARK: Steps

    func execute(_ step: WorkflowStep) throws -> StepReport {
        guard let kind = step.kind else { throw StepFailure(code: .unsupportedAction, message: "unsupported action") }
        let bundle = step.app ?? self.wf.target.bundleIds[0]
        let timeoutMs = step.timeoutMs ?? self.options.defaultStepTimeoutMs
        var report = StepReport(id: step.id, action: kind.rawValue, status: "succeeded", dispatched: false,
                                verified: false, elapsedMs: 0)

        switch kind {
        case .openApp:
            do {
                try self.driver.ensureApp(bundleId: bundle, launch: !self.options.dryRun)
            } catch let e as WorkflowError where self.options.dryRun && e.code == .appNotRunning {
                self.appsNotRunning.insert(bundle)
                self.warnings.append("\(bundle) is not running; a real run would launch it")
                report.status = "skipped"
                return report
            } catch let e as WorkflowError {
                throw StepFailure(code: e.code, message: e.message, dispatched: false)
            }
            // Launching or finding the app sends no input: it does not count as a dispatched action.
            report.verified = true
            return report

        case .selectWindow:
            let matcher = try self.render(step.window ?? WindowMatcher())
            self.windows[bundle] = matcher
            if self.appsNotRunning.contains(bundle) { report.status = "skipped"; return report }
            let obs = try self.poll(bundle: bundle, timeoutMs: timeoutMs, settle: false) { obs in
                matcher.matches(obs.window) ? true : nil
            } onTimeout: { obs in
                StepFailure(code: .wrongWindow, message: "no window matching the step's window matcher",
                            diagnostics: self.diagnostics(obs))
            }
            _ = obs
            report.verified = true
            return report

        case .waitFor, .assert:
            guard let raw = step.condition else { throw StepFailure(code: .schemaInvalid, message: "missing condition") }
            let condition = try self.render(raw)
            let conditionBundle = condition.app ?? bundle
            if self.appsNotRunning.contains(conditionBundle) { report.status = "skipped"; return report }
            if self.options.dryRun {
                let obs = try self.observe(conditionBundle, settle: false)
                let r = ConditionEvaluator.evaluate(condition, in: obs)
                report.status = r.satisfied ? "resolved" : "not_yet_visible"
                report.message = self.safe(r.detail)
                if !r.satisfied, !self.mutatingStepSeen, kind == .assert {
                    throw StepFailure(code: .assertionFailed, message: r.detail, diagnostics: self.diagnostics(obs))
                }
                return report
            }
            let wait = kind == .waitFor ? timeoutMs : min(timeoutMs, 1500)
            _ = try self.poll(bundle: conditionBundle, timeoutMs: wait, settle: self.needsSettle) { obs in
                ConditionEvaluator.evaluate(condition, in: obs).satisfied ? true : nil
            } onTimeout: { obs in
                let detail = ConditionEvaluator.evaluate(condition, in: obs).detail
                return StepFailure(code: kind == .waitFor ? .timeout : .assertionFailed,
                                   message: kind == .waitFor ? "condition not met within \(wait) ms: \(detail)" : detail,
                                   diagnostics: self.diagnostics(obs, condition: detail))
            }
            self.needsSettle = false
            report.verified = true
            return report

        case .click, .typeText, .paste, .setValue, .pressKey, .performAction, .scroll, .drag:
            return try self.executeAction(step, kind: kind, bundle: bundle, timeoutMs: timeoutMs)
        }
    }

    func executeAction(_ step: WorkflowStep, kind: StepAction, bundle: String, timeoutMs: Int) throws -> StepReport {
        var report = StepReport(id: step.id, action: kind.rawValue, status: "succeeded", dispatched: false,
                                verified: false, elapsedMs: 0)
        if self.appsNotRunning.contains(bundle) {
            report.status = "skipped"
            if kind.isMutating { self.mutatingStepSeen = true }
            return report
        }
        let allowCoordinates = step.allowCoordinateFallback == true && self.options.allowCoordinateFallback
        let foreground = step.foreground == true

        // Preconditions.
        for raw in step.preconditions ?? [] {
            let condition = try self.render(raw)
            if self.options.dryRun { continue }
            _ = try self.poll(bundle: condition.app ?? bundle, timeoutMs: timeoutMs, settle: self.needsSettle) { obs in
                ConditionEvaluator.evaluate(condition, in: obs).satisfied ? true : nil
            } onTimeout: { obs in
                let detail = ConditionEvaluator.evaluate(condition, in: obs).detail
                return StepFailure(code: .preconditionFailed, message: detail, diagnostics: self.diagnostics(obs, condition: detail))
            }
            self.needsSettle = false
        }

        // Resolve the target(s) against fresh UI state.
        var element: ElementObservation?
        var toElement: ElementObservation?
        var point: RelativePoint?
        var pid: Int32 = 0
        func resolveAll() throws {
            if let raw = step.target {
                let locator = try self.render(raw)
                let (r, obs) = try self.resolve(locator, bundle: bundle, timeoutMs: timeoutMs, allowCoordinates: allowCoordinates)
                pid = obs.pid
                report.target = self.safe(locator.summary)
                report.strategy = r?.strategy
                report.confidence = r?.confidence
                if let r {
                    switch r.outcome {
                    case let .unique(e): element = e
                    case let .coordinate(p): point = p
                    default: break
                    }
                }
            }
            if let raw = step.toTarget {
                let locator = try self.render(raw)
                let (r, obs) = try self.resolve(locator, bundle: bundle, timeoutMs: timeoutMs, allowCoordinates: allowCoordinates)
                pid = obs.pid
                toElement = r?.element
            }
            if step.target == nil, step.toTarget == nil {
                pid = try self.observe(bundle, settle: false).pid
            }
        }
        try resolveAll()

        if self.options.dryRun {
            report.status = (step.target != nil && element == nil && point == nil) ? "not_yet_visible" : "resolved"
            if kind.isMutating { self.mutatingStepSeen = true }
            return report
        }

        // Actionability, secure fields and authority, immediately before sending.
        let text = try step.value.map { try Template.render($0, inputs: self.inputs) }
        if let element {
            if !element.enabled {
                throw StepFailure(code: .targetNotActionable, message: "\(element.summary) is disabled")
            }
            if kind == .setValue, !element.editable, Self.textRoles.contains(element.role) {
                throw StepFailure(code: .targetNotActionable, message: "\(element.summary) is not editable")
            }
            if kind == .performAction, let action = step.axAction {
                let name = action.hasPrefix("AX") ? action : "AX" + action.prefix(1).uppercased() + action.dropFirst()
                if !element.actions.contains(name) {
                    throw StepFailure(code: .unsupportedAction, message: "\(element.summary) does not offer \(name)")
                }
            }
            if element.secure, kind == .typeText || kind == .paste || kind == .setValue,
               !self.usesOnlySecretInputs(step.value) {
                throw StepFailure(code: .permissionDenied,
                                  message: "secure fields may only be filled from inputs declared secret=true")
            }
        }

        var request = DispatchRequest(
            action: kind, bundleId: bundle, pid: pid, element: element, toElement: toElement, point: point, text: text,
            key: try step.key.map { try Template.render($0, inputs: self.inputs) }, axAction: step.axAction,
            direction: step.direction, pages: step.pages, mouseButton: step.mouseButton, clickCount: step.clickCount,
            foreground: foreground, window: self.windows[bundle])

        var summary = ""
        var retried = false
        while true {
            if self.options.cancel.isCancelled {
                throw StepFailure(code: .cancelled, message: "run cancelled before step '\(step.id)' was sent")
            }
            do {
                summary = try self.driver.dispatch(request)
                break
            } catch let e as WorkflowError {
                if e.dispatched {
                    self.markDispatched(kind)
                    throw StepFailure(code: kind.isMutating ? .outcomeUncertain : .dispatchFailed,
                                      message: "the action may have been sent but failed: \(e.message)", dispatched: true)
                }
                if e.code == .staleObservation, !retried {
                    retried = true
                    element = nil; toElement = nil; point = nil
                    try resolveAll()
                    request.element = element
                    request.toElement = toElement
                    request.point = point
                    request.pid = pid
                    continue
                }
                throw StepFailure(code: e.code, message: e.message)
            }
        }
        self.markDispatched(kind)
        report.dispatched = true
        report.message = self.safe(summary)
        self.needsSettle = true

        // Postconditions: the step only counts as done once they hold.
        let post = try (step.postconditions ?? []).map { try self.render($0) }
        if post.isEmpty {
            report.status = kind.isMutating ? "dispatched_unverified" : "succeeded"
            return report
        }
        for condition in post {
            _ = try self.poll(bundle: condition.app ?? bundle, timeoutMs: timeoutMs, settle: self.needsSettle) { obs in
                ConditionEvaluator.evaluate(condition, in: obs).satisfied ? true : nil
            } onTimeout: { obs in
                let detail = ConditionEvaluator.evaluate(condition, in: obs).detail
                return StepFailure(code: kind.isMutating ? .postconditionFailed : .postconditionFailed,
                                   message: "postcondition not met within \(timeoutMs) ms: \(detail)",
                                   dispatched: true, diagnostics: self.diagnostics(obs, condition: detail))
            }
            self.needsSettle = false
        }
        report.verified = true
        return report
    }

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    func markDispatched(_ kind: StepAction) {
        self.anyDispatched = true
        if kind.isMutating {
            self.anyMutatingDispatched = true
            self.mutatingStepSeen = true
        }
    }

    func usesOnlySecretInputs(_ template: String?) -> Bool {
        guard let template, let segments = try? Template.parse(template) else { return false }
        let refs = segments.compactMap(\.reference)
        return !refs.isEmpty && segments.allSatisfy { $0.literal.isEmpty }
            && refs.allSatisfy { self.wf.inputs[$0]?.isSecret == true }
    }

    // MARK: Observation helpers

    func observe(_ bundle: String, settle: Bool) throws -> UIObservation {
        if self.options.dryRun, let cached = self.dryRunObservations[bundle] { return cached }
        do {
            let obs = try self.driver.observe(bundleId: bundle, window: self.windows[bundle], settle: settle)
            if let observed = obs.bundleId, observed != bundle {
                throw StepFailure(code: .wrongApplication,
                                  message: "expected \(bundle) but observed \(observed)",
                                  diagnostics: RunDiagnostics(observedBundleId: observed))
            }
            if self.options.dryRun { self.dryRunObservations[bundle] = obs }
            return obs
        } catch let e as WorkflowError {
            throw StepFailure(code: e.code, message: e.message)
        }
    }

    /// Polls fresh observations until `check` returns a value or the step times out.
    func poll<T>(bundle: String, timeoutMs: Int, settle: Bool, _ check: (UIObservation) throws -> T?,
                 onTimeout: (UIObservation) -> StepFailure) throws -> T {
        let stepDeadline = min(self.deadline, Date().addingTimeInterval(Double(timeoutMs) / 1000))
        var first = true
        while true {
            let obs = try self.observe(bundle, settle: settle && first)
            first = false
            if let value = try check(obs) { return value }
            if self.options.dryRun || Date() >= stepDeadline { throw onTimeout(obs) }
            if self.options.cancel.isCancelled { throw StepFailure(code: .cancelled, message: "run cancelled") }
            self.options.sleep(self.options.pollIntervalMs)
        }
    }

    /// Resolves until unique (or the step times out). Ambiguity that persists across two fresh observations
    /// refuses the step; nothing is ever picked from several candidates.
    func resolve(_ locator: ElementLocator, bundle: String, timeoutMs: Int,
                 allowCoordinates: Bool) throws -> (Resolution?, UIObservation) {
        var ambiguousSeen = 0
        var lastObs: UIObservation?
        let settle = self.needsSettle
        do {
            let value: (Resolution?, UIObservation) = try self.poll(bundle: bundle, timeoutMs: timeoutMs, settle: settle) { obs in
                lastObs = obs
                if let matcher = locator.window, !matcher.matches(obs.window) { return nil }
                let r = SelectorResolver.resolve(locator, in: obs, allowCoordinateFallback: allowCoordinates)
                switch r.outcome {
                case .unique, .coordinate:
                    return (r, obs)
                case let .ambiguous(candidates):
                    ambiguousSeen += 1
                    if ambiguousSeen >= 2 || self.options.dryRun {
                        throw StepFailure(
                            code: .ambiguousTarget,
                            message: "\(candidates.count) elements match \(locator.summary); refusing to guess",
                            diagnostics: self.diagnostics(obs, candidates: candidates))
                    }
                    return nil
                case .notFound:
                    return nil
                }
            } onTimeout: { obs in
                if let matcher = locator.window, !matcher.matches(obs.window) {
                    return StepFailure(code: .wrongWindow, message: "the target's window is not the current window",
                                       diagnostics: self.diagnostics(obs))
                }
                let r = SelectorResolver.resolve(locator, in: obs)
                return StepFailure(code: .targetNotFound, message: "no element matches \(locator.summary)",
                                   diagnostics: self.diagnostics(obs, nearMisses: r.nearMisses))
            }
            self.needsSettle = false
            return value
        } catch let failure as StepFailure where self.options.dryRun && failure.code == .targetNotFound && self.mutatingStepSeen {
            // Earlier steps would change the UI first; a later target being absent now is expected.
            return (nil, lastObs ?? UIObservation(bundleId: bundle, pid: 0, appName: bundle, window: nil, elements: []))
        }
    }

    func render(_ locator: ElementLocator) throws -> ElementLocator {
        do { return try locator.mapStrings { try Template.render($0, inputs: self.inputs) } } catch {
            throw StepFailure(code: .invalidInput, message: "\(error)")
        }
    }

    func render(_ matcher: WindowMatcher) throws -> WindowMatcher {
        var m = matcher
        do {
            m.title = try matcher.title.map { try Template.render($0, inputs: self.inputs) }
            m.titleContains = try matcher.titleContains.map { try Template.render($0, inputs: self.inputs) }
        } catch {
            throw StepFailure(code: .invalidInput, message: "\(error)")
        }
        return m
    }

    func render(_ condition: Condition) throws -> Condition {
        var c = condition
        c.target = try condition.target.map { try self.render($0) }
        do { c.value = try condition.value.map { try Template.render($0, inputs: self.inputs) } } catch {
            throw StepFailure(code: .invalidInput, message: "\(error)")
        }
        return c
    }

    // MARK: Results

    /// Strips secret input values and credential-like text from anything returned or stored.
    func safe(_ text: String) -> String {
        var out = text
        for secret in self.secretValues where secret.count >= 1 {
            out = out.replacingOccurrences(of: secret, with: "[SECRET]")
        }
        return Redactor.sanitize(out, limit: 600)
    }

    func diagnostics(_ obs: UIObservation, candidates: [ElementObservation]? = nil,
                     nearMisses: [ElementObservation]? = nil, condition: String? = nil) -> RunDiagnostics {
        RunDiagnostics(
            candidates: candidates?.prefix(6).map { self.safe($0.summary) },
            nearMisses: nearMisses.flatMap { $0.isEmpty ? nil : $0.map { self.safe($0.summary) } },
            observedBundleId: obs.bundleId,
            observedWindow: obs.window?.title.map { self.safe(Redactor.clip($0, 120)) },
            elementCount: obs.elements.count,
            condition: condition.map(self.safe))
    }

    static func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }

    func result(failure: StepFailure?, stepId: String?) -> WorkflowRunResult {
        let status: RunStatus
        if let failure {
            if self.options.dryRun {
                status = .dryRunFailed
            } else if failure.code == .cancelled {
                status = .cancelled
            } else if failure.dispatched, self.anyMutatingDispatched {
                status = .uncertain
            } else if !self.anyDispatched {
                status = .refused
            } else {
                status = .failed
            }
        } else {
            status = self.options.dryRun ? .dryRunPassed : .succeeded
        }
        var outputs: [String: String]?
        if failure == nil, !self.options.dryRun, let specs = self.wf.outputs, !specs.isEmpty {
            outputs = self.readOutputs(specs)
        }
        if failure == nil, !self.options.dryRun, !self.wf.hasVerification {
            self.warnings.append("the workflow has no verification steps; success only means every action was sent")
        }
        return WorkflowRunResult(
            runId: self.runId, workflowId: self.wf.id, revision: self.wf.revision, status: status,
            dryRun: self.options.dryRun, code: failure?.code, message: failure.map { self.safe($0.message) },
            failedStepId: failure == nil ? nil : stepId, completedSteps: self.completed, steps: self.reports,
            actionDispatched: self.anyDispatched, possibleCommit: self.anyMutatingDispatched,
            retrySafe: !self.anyMutatingDispatched, recovery: failure?.code.recovery, diagnostics: failure?.diagnostics,
            diagnosticId: failure == nil ? nil : IDs.make("diag"), outputs: outputs, warnings: self.warnings,
            startedAt: ISO8601DateFormatter().string(from: self.started), elapsedMs: Self.ms(since: self.started))
    }

    func readOutputs(_ specs: [String: ElementLocator]) -> [String: String] {
        var out: [String: String] = [:]
        let bundle = self.wf.target.bundleIds[0]
        guard let obs = try? self.observe(bundle, settle: true) else { return out }
        for (name, raw) in specs {
            guard let locator = try? self.render(raw) else { continue }
            let r = SelectorResolver.resolve(locator, in: obs)
            if let e = r.element, !e.secure, let value = e.value ?? e.title ?? e.description {
                out[name] = self.safe(Redactor.clip(value, 2000))
            } else {
                self.warnings.append("output '\(name)' could not be read (target \(r.element == nil ? "not unique" : "has no value"))")
            }
        }
        return out
    }
}
