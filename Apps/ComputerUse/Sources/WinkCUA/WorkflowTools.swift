import AppKit
import WinkWorkflowKit

/// MCP surface for workflows (record -> compile -> validate -> run) and agent feedback. Kept out of
/// MCPServer.swift; the logic itself lives in WinkWorkflowKit.
final class WorkflowService {
    let engine: Engine
    let store: WorkflowStore
    let feedback: FeedbackStore
    let recorder = WorkflowRecorder()
    let diagnostics = DiagnosticLog()
    let version: String
    private var lastRecordingId: String?
    private let runLock = NSLock()
    private var activeRun: (requestId: String, token: CancellationToken)?

    init(engine: Engine, version: String, store: WorkflowStore = .defaultStore(), feedback: FeedbackStore = .defaultStore()) {
        self.engine = engine
        self.version = version
        self.store = store
        self.feedback = feedback
    }

    /// Tools that never touch app UI (no session events, no recording).
    static let dataTools: Set<String> = [
        "feedback_submit", "feedback_list", "feedback_get", "feedback_delete", "feedback_export",
        "workflow_record_start", "workflow_record_stop", "workflow_compile", "workflow_save", "workflow_list",
        "workflow_get", "workflow_validate", "workflow_delete",
    ]
    static let toolNames: Set<String> = dataTools.union(["workflow_run"])

    // MARK: Definitions

    var definitions: [[String: Any]] {
        func schema(_ props: [String: Any], _ required: [String] = []) -> [String: Any] {
            ["type": "object", "properties": props, "required": required]
        }
        let str: [String: Any] = ["type": "string"]
        let bool: [String: Any] = ["type": "boolean"]
        let obj: [String: Any] = ["type": "object"]
        let id: [String: Any] = ["type": "string", "description": "Workflow id"]
        let rev: [String: Any] = ["type": "integer", "description": "Revision (default: latest)"]
        return [
            ["name": "feedback_submit",
             "description": """
             Report a genuine Wink limitation, bug or missing capability so it can be fixed. Use it once per problem, with a \
             useful reproduction and the capability you needed (wish) — identical reports are merged and counted, not \
             duplicated. Stored locally only (nothing is uploaded); secrets and personal data are redacted. Works with or \
             without workflow recording.
             """,
             "inputSchema": schema([
                 "category": ["type": "string", "enum": FeedbackCategory.allCases.map(\.rawValue)],
                 "severity": ["type": "string", "enum": FeedbackSeverity.allCases.map(\.rawValue)],
                 "summary": ["type": "string", "description": "One sentence: what is wrong or missing"],
                 "expected": str, "actual": str,
                 "wish": ["type": "string", "description": "The capability or tool you needed"],
                 "tool": ["type": "string", "description": "Wink tool involved, e.g. scroll"],
                 "error_code": str, "workflow_id": str, "run_id": str, "diagnostic_id": str,
                 "repro_steps": ["type": "array", "items": str, "description": "Sanitized steps (no secrets)"],
                 "attach_recent_diagnostics": ["type": "boolean",
                                               "description": "Attach the last tool outcomes (tool, app, status, timing; no UI content)"],
                 "client": ["type": "string", "description": "Your agent/client name"],
             ], ["category", "summary"])],
            ["name": "feedback_list", "description": "List locally stored feedback reports (newest first).",
             "inputSchema": schema(["limit": ["type": "integer"]])],
            ["name": "feedback_get", "description": "Show one feedback report.", "inputSchema": schema(["id": str], ["id"])],
            ["name": "feedback_delete", "description": "Delete one feedback report.", "inputSchema": schema(["id": str], ["id"])],
            ["name": "feedback_export",
             "description": "Export all feedback as markdown or JSON text (returned here; nothing is sent anywhere).",
             "inputSchema": schema(["format": ["type": "string", "enum": ["markdown", "json"]]])],

            ["name": "workflow_record_start",
             "description": """
             Start recording your Wink actions (click, type_text, paste, set_value, press_key, perform_action, scroll, drag, \
             and get_app_state window choices) so they can become a reusable workflow. Wink stores semantic targets (role, \
             identifier, names, ancestors), never element indices. Secure-field text and credential-like text is never \
             recorded. Off by default; only one recording at a time.
             """,
             "inputSchema": schema([
                 "name": ["type": "string", "description": "What the task does, e.g. \"Add two numbers in Calculator\""],
                 "apps": ["type": "array", "items": str, "description": "Only record these apps (names or bundle ids)"],
                 "capture_text": ["type": "boolean",
                                  "description": "Keep typed text as example literals for parameterization (default true)"],
             ])],
            ["name": "workflow_record_stop", "description": "Stop recording and store the draft recording. Returns its actions.",
             "inputSchema": schema([:])],
            ["name": "workflow_compile",
             "description": """
             Compile a recording into a draft workflow and save it (new revision if the id exists). You decide what \
             generalizes: map example literals to inputs (parameters), drop exploration (exclude), and add verification \
             (append_steps with wait_for/assert, or auto_verify). Returns warnings, parameter candidates and suggested \
             verifications.
             """,
             "inputSchema": schema([
                 "recording_id": ["type": "string", "description": "Default: the recording just stopped"],
                 "id": ["type": "string", "description": "Workflow id: lowercase letters, digits, _ and -"],
                 "name": str, "description": str,
                 "parameters": ["type": "object",
                                "description": "{\"input_name\": {\"example\": \"literal from the recording\", \"type\": \"string\", \"description\": \"…\"}}"],
                 "exclude": ["type": "array", "items": ["type": "integer"], "description": "Recorded action seq numbers to drop"],
                 "append_steps": ["type": "array", "items": obj, "description": "Steps to append, e.g. wait_for conditions"],
                 "auto_verify": ["type": "boolean", "description": "Append the strongest suggested verification"],
                 "outputs": ["type": "object", "description": "{\"name\": <target locator>} values to read after the run"],
                 "effect": ["type": "string", "enum": WorkflowEffect.allCases.map(\.rawValue)],
                 "save": ["type": "boolean", "description": "Save the draft (default true)"],
                 "allow_scope_change": bool,
             ])],
            ["name": "workflow_save",
             "description": """
             Save an edited workflow definition as a new draft revision, change a workflow's status \
             (draft|validated|published|disabled; publishing needs verification), or roll back to an older revision. \
             Changes that widen apps, effect, foreground use or action kinds need allow_scope_change=true (ask the user first).
             """,
             "inputSchema": schema([
                 "workflow": ["type": "object", "description": "Full workflow JSON (see workflow_get)"],
                 "id": id, "status": ["type": "string", "enum": WorkflowStatus.allCases.map(\.rawValue)],
                 "rollback_to": ["type": "integer", "description": "Copy this revision forward as a new draft"],
                 "expected_revision": ["type": "integer", "description": "Fail if the latest revision differs"],
                 "allow_scope_change": bool,
             ])],
            ["name": "workflow_list", "description": "List saved workflows and recordings.", "inputSchema": schema([:])],
            ["name": "workflow_get", "description": "Show a workflow definition, its revisions and its validation report.",
             "inputSchema": schema(["id": id, "revision": rev], ["id"])],
            ["name": "workflow_validate",
             "description": "Statically validate a saved workflow (or an inline one) and optional inputs; mark_validated records a pass.",
             "inputSchema": schema([
                 "id": id, "revision": rev, "workflow": obj, "inputs": obj,
                 "mark_validated": ["type": "boolean", "description": "Set status=validated if it passes"],
             ])],
            ["name": "workflow_run",
             "description": """
             Run a saved workflow deterministically (no model): each step's target is resolved semantically against fresh \
             UI, checked, sent with Wink's normal background input, and verified. Fails closed on missing/ambiguous targets \
             or the wrong app/window. Read status, code, action_dispatched, possible_commit and retry_safe: never rerun a \
             run with possible_commit=true without inspecting the app. dry_run=true resolves targets without acting.
             """,
             "inputSchema": schema([
                 "id": id, "revision": rev,
                 "inputs": ["type": "object", "description": "Values for the workflow's inputs"],
                 "dry_run": ["type": "boolean", "description": "Validate and resolve only; send nothing"],
                 "allow_foreground": ["type": "boolean", "description": "Permit steps that activate the app (default false)"],
                 "allow_coordinate_fallback": ["type": "boolean", "description": "Permit authored coordinate fallbacks (default false)"],
                 "timeout_ms": ["type": "integer", "description": "Whole-run limit (default 120000)"],
             ], ["id"])],
            ["name": "workflow_delete", "description": "Delete a workflow and all its revisions.",
             "inputSchema": schema(["id": id], ["id"])],
        ]
    }

    // MARK: Dispatch

    /// Handles workflow/feedback tools; nil for any other tool name.
    func handle(_ name: String, _ args: [String: Any], requestId: String? = nil) -> ToolOutput? {
        guard Self.toolNames.contains(name) else { return nil }
        do {
            switch name {
            case "feedback_submit": return try self.feedbackSubmit(args)
            case "feedback_list":
                let limit = max(1, min(args.int("limit") ?? 50, 500))
                let items = self.feedback.all().prefix(limit).map { r -> [String: Any] in
                    var item: [String: Any] = ["id": r.id, "summary": r.summary, "category": r.category.rawValue,
                                               "severity": r.severity.rawValue, "occurrences": r.occurrences,
                                               "updated_at": r.updatedAt]
                    if let tool = r.tool { item["tool"] = tool }
                    return item
                }
                return self.ok(["reports": Array(items), "count": items.count, "stored_at": self.feedback.root.path])
            case "feedback_get": return self.ok(WorkflowJSON.object(try self.feedback.get(try args.string("id"))))
            case "feedback_delete":
                let id = try args.string("id")
                try self.feedback.delete(id)
                return self.ok(["deleted": id])
            case "feedback_export":
                let format = (args["format"] as? String) == "json" ? "json" : "markdown"
                return ToolOutput(text: self.feedback.export(format: format), structured: ["format": format])
            case "workflow_record_start": return try self.recordStart(args)
            case "workflow_record_stop": return try self.recordStop()
            case "workflow_compile": return try self.compile(args)
            case "workflow_save": return try self.save(args)
            case "workflow_list":
                return self.ok(["workflows": WorkflowJSON.object(self.store.list()),
                                "recordings": self.store.listRecordings(),
                                "recording_active": self.recorder.activeId as Any? ?? NSNull()])
            case "workflow_get":
                let id = try args.string("id")
                let wf = try self.store.load(id, revision: args.int("revision"))
                return self.ok(["workflow": WorkflowJSON.object(wf), "revisions": try self.store.revisions(of: id),
                                "validation": WorkflowJSON.object(WorkflowValidator.validate(wf))])
            case "workflow_validate": return try self.validate(args)
            case "workflow_run": return try self.run(args, requestId: requestId)
            case "workflow_delete":
                let id = try args.string("id")
                try self.store.delete(id)
                return self.ok(["deleted": id])
            default: return nil
            }
        } catch let error as WorkflowError {
            return self.failure(error)
        } catch let error as ToolError {
            return self.failure(WorkflowError(.invalidArgument, error.description))
        } catch {
            return self.failure(WorkflowError(.invalidArgument, WorkflowJSON.describe(error)))
        }
    }

    /// Called from the stdin reader thread for MCP notifications/cancelled.
    func cancel(requestId: String) {
        self.runLock.lock()
        defer { self.runLock.unlock() }
        if let active = self.activeRun, active.requestId == requestId { active.token.cancel() }
    }

    // MARK: Recording hooks (called by MCPServer around ordinary tools)

    func beforeTool(_ name: String, _ args: [String: Any]) -> RecordingCapture? {
        guard self.recorder.isActive else { return nil }
        return RecordingCapture.before(tool: name, args: args, engine: self.engine, recorder: self.recorder)
    }

    func afterTool(_ name: String, _ args: [String: Any], capture: RecordingCapture?, error: Error?, isError: Bool) {
        guard self.recorder.isActive else { return }
        if let capture {
            self.recorder.append(capture.finish(engine: self.engine, error: error, isError: isError))
        } else if name == "get_app_state", error == nil, !isError,
                  let selection = RecordingCapture.windowSelection(args: args, engine: self.engine, recorder: self.recorder) {
            self.recorder.append(selection)
        }
    }

    // MARK: Handlers

    private func feedbackSubmit(_ args: [String: Any]) throws -> ToolOutput {
        let submission: FeedbackSubmission
        do {
            submission = try WorkflowJSON.decode(FeedbackSubmission.self, fromAny: args)
        } catch {
            throw WorkflowError(.invalidArgument, "invalid feedback: \(WorkflowJSON.describe(error)). category is one of "
                + FeedbackCategory.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let result = try self.feedback.submit(
            submission, environment: FeedbackEnvironment(component: "wink-cua", version: self.version),
            diagnostics: submission.attachRecentDiagnostics == true ? self.diagnostics.recent(10) : [])
        var out = WorkflowJSON.object(result) as? [String: Any] ?? [:]
        out["note"] = result.status == "merged"
            ? "An identical report already existed; its occurrence count went up. No need to report it again."
            : "Saved locally (\(self.feedback.root.path)); nothing was uploaded."
        return self.ok(out)
    }

    private func recordStart(_ args: [String: Any]) throws -> ToolOutput {
        let apps = (args["apps"] as? [Any] ?? []).map { "\($0)" }.map { query -> String in
            if let app = try? self.engine.resolve(query, launch: false), let bundle = app.bundleIdentifier { return bundle }
            if let url = self.engine.applicationURL(for: query), let bundle = Bundle(url: url)?.bundleIdentifier { return bundle }
            return query
        }
        let recording = try self.recorder.start(name: args["name"] as? String, apps: apps,
                                                captureText: args.bool("capture_text") ?? true)
        self.engine.captureEvidence = true
        return self.ok([
            "recording_id": recording.id, "status": "recording", "apps": apps, "capture_text": recording.captureText,
            "next": "Use Wink tools as usual (get_app_state first, then actions). Call workflow_record_stop when the task succeeded.",
        ])
    }

    private func recordStop() throws -> ToolOutput {
        let recording = try self.recorder.stop()
        self.engine.captureEvidence = false
        try self.store.saveRecording(recording)
        self.lastRecordingId = recording.id
        let actions = recording.actions.map { a -> [String: Any] in
            var item: [String: Any] = ["seq": a.seq, "action": a.action, "status": a.status, "outcome": a.outcome,
                                       "dispatched": a.dispatched]
            if let t = a.target { item["target"] = t.summary }
            if let b = a.bundleId { item["app"] = b }
            if let text = a.text { item["text"] = text.literal.map { Redactor.clip($0, 80) } ?? "[\(text.reason ?? "redacted"), \(text.length) chars]" }
            if let k = a.key { item["key"] = k }
            if let w = a.windowSelector { item["window"] = w }
            return item
        }
        return self.ok([
            "recording_id": recording.id, "actions": actions, "dropped_actions": recording.droppedActions,
            "next": "Call workflow_compile with an id, parameters for literals that should become inputs, and a verification.",
        ])
    }

    private func compile(_ args: [String: Any]) throws -> ToolOutput {
        guard let recordingId = (args["recording_id"] as? String) ?? self.lastRecordingId else {
            throw WorkflowError(.invalidArgument, "recording_id is required (no recording was stopped in this session)")
        }
        let recording = try self.store.loadRecording(recordingId)
        var optionArgs = args
        for key in ["recording_id", "save", "allow_scope_change"] { optionArgs.removeValue(forKey: key) }
        let options: CompileOptions
        do {
            options = try WorkflowJSON.decode(CompileOptions.self, fromAny: optionArgs)
        } catch {
            throw WorkflowError(.invalidArgument, "invalid compile options: \(WorkflowJSON.describe(error))")
        }
        var report = try WorkflowCompiler.compile(recording, options: options)
        var saved = false
        if args.bool("save") ?? true {
            report.workflow = try self.store.save(report.workflow, allowScopeChange: args.bool("allow_scope_change") ?? false)
            saved = true
        }
        var out = WorkflowJSON.object(report) as? [String: Any] ?? [:]
        out["saved"] = saved
        out["validation"] = WorkflowJSON.object(WorkflowValidator.validate(report.workflow))
        return self.ok(out)
    }

    private func save(_ args: [String: Any]) throws -> ToolOutput {
        let allowScope = args.bool("allow_scope_change") ?? false
        if let raw = args["workflow"] {
            let data: Data
            if let text = raw as? String { data = Data(text.utf8) } else {
                guard JSONSerialization.isValidJSONObject(raw) else { throw WorkflowError(.invalidArgument, "workflow must be an object") }
                data = try JSONSerialization.data(withJSONObject: raw)
            }
            var wf = try WorkflowValidator.decode(data)
            if wf.provenance == nil { wf.provenance = Provenance(source: "edited") }
            let saved = try self.store.save(wf, expectedRevision: args.int("expected_revision"), allowScopeChange: allowScope)
            return self.ok(["workflow": WorkflowJSON.object(saved),
                            "validation": WorkflowJSON.object(WorkflowValidator.validate(saved))])
        }
        let id = try args.string("id")
        if let rev = args.int("rollback_to") {
            let saved = try self.store.rollback(id, to: rev)
            return self.ok(["workflow": WorkflowJSON.object(saved), "rolled_back_to": rev])
        }
        if let raw = args["status"] as? String {
            guard let status = WorkflowStatus(rawValue: raw) else { throw WorkflowError(.invalidArgument, "unknown status '\(raw)'") }
            let saved = try self.store.setStatus(id, status)
            return self.ok(["id": saved.id, "revision": saved.revision, "status": saved.status.rawValue])
        }
        throw WorkflowError(.invalidArgument, "pass workflow, or id with status or rollback_to")
    }

    private func validate(_ args: [String: Any]) throws -> ToolOutput {
        let wf: Workflow
        if let raw = args["workflow"] {
            let data = try (raw as? String).map { Data($0.utf8) } ?? JSONSerialization.data(withJSONObject: raw)
            wf = try WorkflowValidator.decode(data)
        } else {
            wf = try self.store.load(try args.string("id"), revision: args.int("revision"))
        }
        var report = WorkflowValidator.validate(wf)
        if let inputs = args["inputs"] as? [String: Any] {
            do { _ = try InputBinder.bind(inputs, spec: wf.inputs) } catch let e as WorkflowError {
                report.valid = false
                report.errors.append(ValidationIssue(code: e.code, path: "inputs", message: e.message))
            }
        }
        var out = WorkflowJSON.object(report) as? [String: Any] ?? [:]
        if report.valid, args.bool("mark_validated") == true, args["workflow"] == nil, wf.status == .draft {
            let marked = try self.store.setStatus(wf.id, .validated)
            out["status"] = marked.status.rawValue
        }
        let output = self.ok(out)
        return report.valid ? output : ToolOutput(text: output.text, isError: true, structured: output.structured)
    }

    private func run(_ args: [String: Any], requestId: String?) throws -> ToolOutput {
        let wf = try self.store.load(try args.string("id"), revision: args.int("revision"))
        var options = RunOptions()
        options.dryRun = args.bool("dry_run") ?? false
        options.allowForeground = args.bool("allow_foreground") ?? false
        options.allowCoordinateFallback = args.bool("allow_coordinate_fallback") ?? false
        if let t = args.int("timeout_ms") { options.timeoutMs = max(1000, min(t, 600_000)) }
        let inputs: [String: Any]
        if let text = args["inputs"] as? String {
            inputs = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
        } else {
            inputs = args["inputs"] as? [String: Any] ?? [:]
        }
        let token = options.cancel
        self.runLock.lock()
        self.activeRun = requestId.map { ($0, token) }
        self.runLock.unlock()
        defer {
            self.runLock.lock()
            self.activeRun = nil
            self.runLock.unlock()
        }
        let driver = CUAWorkflowDriver(engine: self.engine)
        var result = WorkflowRunner(driver: driver).run(wf, inputs: inputs, options: options)
        driver.restore()
        if wf.status == .draft, !options.dryRun {
            result.warnings.append("ran a draft revision; validate and publish it once it is reliable")
        }
        self.store.saveRun(result)
        if let code = result.code {
            self.diagnostics.record(tool: "workflow_run", app: wf.target.bundleIds.first, ok: false, code: code.rawValue,
                                    elapsedMs: result.elapsedMs, message: result.message)
        }
        let structured = WorkflowJSON.object(result) as? [String: Any] ?? [:]
        let ok = result.status == .succeeded || result.status == .dryRunPassed
        let headline = "workflow_run \(wf.id) r\(wf.revision): \(result.status.rawValue)"
            + (result.code.map { " \($0.rawValue)" } ?? "")
        return ToolOutput(text: headline + "\n" + WorkflowJSON.string(result), isError: !ok, structured: structured)
    }

    // MARK: Output helpers

    private func ok(_ value: Any) -> ToolOutput {
        let dict = value as? [String: Any] ?? ["result": value]
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
        return ToolOutput(text: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}", structured: dict)
    }

    private func failure(_ error: WorkflowError) -> ToolOutput {
        let dict: [String: Any] = ["status": "error", "code": error.code.rawValue, "message": error.message,
                                   "recovery": error.code.recovery]
        return ToolOutput(text: "Error \(error.code.rawValue): \(error.message)\nRecovery: \(error.code.recovery)",
                          isError: true, structured: dict)
    }
}
