import Foundation
import Testing
@testable import WinkWorkflowKit

@Suite struct CompilerTests {
    /// What wink-cua records for: type "Groceries" into the Title field, click Save.
    static func recording(text: String = "Groceries", secure: Bool = false, captureText: Bool = true) -> Recording {
        var type = RecordedAction(seq: 1, tool: "type_text", action: .typeText, bundleId: Fixtures.notes)
        type.target = LocatorBuilder.locator(for: Fixtures.field(placeholder: "Title"))
        type.targetSecure = secure
        type.text = RecordedText.capture(text, secureTarget: secure, captureText: captureText)
        type.dispatched = true
        var misclick = RecordedAction(seq: 2, tool: "click", action: .click, bundleId: Fixtures.notes)
        misclick.target = ElementLocator(role: "AXButton", title: "Nope")
        misclick.status = "error"
        misclick.dispatched = false
        var save = RecordedAction(seq: 3, tool: "click", action: .click, bundleId: Fixtures.notes)
        save.target = LocatorBuilder.locator(for: Fixtures.button("Save", id: "save"))
        save.dispatched = true
        save.evidence = ActionEvidence.diff(
            before: [:], after: [(key: "W/x", element: Fixtures.text("Saved: \(text)", description: "status"))],
            windowTitle: "Main")
        if type.text?.redacted == true { save.evidence = save.evidence?.scrubbing(text) } // as the recorder does
        return Recording(schemaVersion: 1, id: "rec_test1", name: "Save note", startedAt: WorkflowClock.now(), stoppedAt: nil,
                         captureText: captureText, apps: [], actions: [type, misclick, save], droppedActions: 0)
    }

    @Test func compilesRecordingIntoParameterizedDraft() throws {
        var options = CompileOptions()
        options.id = "save_note"
        options.parameters = ["title": ParameterSpec(example: "Groceries", type: "string", description: "Note title")]
        options.autoVerify = true
        let report = try WorkflowCompiler.compile(Self.recording(), options: options)
        let wf = report.workflow
        #expect(wf.steps.map(\.action) == ["open_app", "type_text", "click", "wait_for"])
        #expect(wf.steps[1].value == "${title}")
        #expect(wf.inputs["title"]?.description == "Note title")
        #expect(wf.steps[2].target?.identifier == "save")
        #expect(wf.status == .draft)
        #expect(wf.provenance?.recordingId == "rec_test1")
        #expect(report.skipped.contains { $0.hasPrefix("#2") })
        // The suggested verification picked up the parameter too.
        #expect(wf.steps[3].condition?.kind == "value_equals")
        #expect(wf.steps[3].condition?.value == "Saved: ${title}")
        #expect(WorkflowValidator.validate(wf).valid)
        // Never an element index anywhere in the definition.
        let json = WorkflowJSON.string(wf)
        #expect(!json.contains("handle"))
        #expect(!json.contains("element_index"))

        // The compiled draft actually runs against the (renumbered) mock app with a new input.
        let driver = Fixtures.notesDriver()
        let result = WorkflowRunner(driver: driver).run(wf, inputs: ["title": "Taxes"], options: Fixtures.fastOptions())
        #expect(result.status == .succeeded, "\(result.code?.rawValue ?? "") \(result.message ?? "")")
    }

    @Test func redactedTextBecomesARequiredInput() throws {
        let report = try WorkflowCompiler.compile(Self.recording(text: "hunter2", secure: true), options: CompileOptions())
        let json = WorkflowJSON.string(report)
        #expect(!json.contains("hunter2"))
        let input = report.workflow.inputs.values.first
        #expect(input?.isSecret == true)
        #expect(input?.isRequired == true)
    }

    @Test func secretLookingTextIsNeverRecorded() {
        let t = RecordedText.capture("token=ghp_abcdefghijklmnopqrstuvwxyz123456", secureTarget: false, captureText: true)
        #expect(t.literal == nil)
        #expect(t.reason == "looks_secret")
        let off = RecordedText.capture("hello", secureTarget: false, captureText: false)
        #expect(off.literal == nil)
    }

    @Test func unsupportedRecordingsFail() {
        var r = Self.recording()
        r.actions = []
        #expect(throws: WorkflowError.self) { try WorkflowCompiler.compile(r, options: CompileOptions()) }
    }
}

@Suite struct RecorderTests {
    @Test func inactiveRecorderCapturesNothing() throws {
        let recorder = WorkflowRecorder()
        #expect(!recorder.isActive)
        #expect(recorder.wants(bundleId: "com.example") == nil)
        recorder.append(RecordedAction(seq: 1, tool: "click", action: .click, bundleId: "com.example"))
        #expect(throws: WorkflowError.self) { try recorder.stop() }

        _ = try recorder.start(name: "x", apps: ["com.only"], captureText: true)
        #expect(recorder.wants(bundleId: "com.example") == nil) // filtered app
        #expect(recorder.wants(bundleId: "com.only")?.seq == 1)
        recorder.append(RecordedAction(seq: 1, tool: "click", action: .click, bundleId: "com.only"))
        #expect(throws: WorkflowError.self) { try recorder.start(name: nil, apps: [], captureText: true) }
        let done = try recorder.stop()
        #expect(done.actions.count == 1)
        #expect(!recorder.isActive)
    }
}

@Suite struct StoreTests {
    @Test func saveReloadRevisionsAndPermissions() throws {
        let root = Fixtures.tempDir()
        let store = WorkflowStore(root: root)
        let first = try store.save(Fixtures.notesWorkflow())
        #expect(first.revision == 1)
        #expect(first.status == .draft)
        let loaded = try store.load("save_note")
        #expect(loaded == first)
        #expect(WorkflowValidator.validate(loaded).valid)

        // Unchanged content: no new revision.
        #expect(try store.save(loaded).revision == 1)

        var edited = loaded
        edited.steps[3].timeoutMs = 9000
        let second = try store.save(edited, expectedRevision: 1)
        #expect(second.revision == 2)
        #expect(try store.revisions(of: "save_note") == [1, 2])
        #expect(throws: WorkflowError.self) { try store.save(edited, expectedRevision: 1) }

        let published = try store.setStatus("save_note", .published)
        #expect(published.status == .published)
        let rolled = try store.rollback("save_note", to: 1)
        #expect(rolled.revision == 3)
        #expect(rolled.status == .draft)
        #expect(rolled.steps[3].timeoutMs == 200)

        let dir = root.appendingPathComponent("definitions/save_note")
        #expect(Fixtures.permissions(dir) == 0o700)
        #expect(Fixtures.permissions(dir.appendingPathComponent("r1.json")) == 0o600)
        #expect(store.list().map(\.id) == ["save_note"])
        try store.delete("save_note")
        #expect(store.list().isEmpty)
    }

    @Test func scopeChangesNeedApproval() throws {
        let store = WorkflowStore(root: Fixtures.tempDir())
        try store.save(Fixtures.notesWorkflow())
        var widened = Fixtures.notesWorkflow()
        widened.target.bundleIds.append("com.apple.Terminal")
        #expect(throws: WorkflowError.self) { try store.save(widened) }
        var newAction = Fixtures.notesWorkflow()
        var key = WorkflowStep(id: "enter", action: .pressKey)
        key.key = "Return"
        newAction.steps.insert(key, at: 3)
        do {
            try store.save(newAction)
            Issue.record("a new action kind must need approval")
        } catch let e as WorkflowError {
            #expect(e.code == .scopeChangeNeedsApproval)
        }
        #expect(try store.save(newAction, allowScopeChange: true).revision == 2)
    }

    @Test func rejectsMalformedAndMaliciousDefinitions() throws {
        // Path traversal ids never reach the filesystem.
        var evil = Fixtures.notesWorkflow()
        evil.id = "../../etc"
        #expect(throws: WorkflowError.self) { try WorkflowStore(root: Fixtures.tempDir()).save(evil) }
        #expect(throws: WorkflowError.self) { try WorkflowStore(root: Fixtures.tempDir()).load("../x") }

        // Unknown actions and executable payloads are rejected as unsupported.
        let shell = #"{"id":"x","target":{"bundle_ids":["com.a.b"]},"steps":[{"id":"s1","action":"shell","value":"rm -rf ~"}]}"#
        let wf = try WorkflowValidator.decode(Data(shell.utf8))
        let report = WorkflowValidator.validate(wf)
        #expect(!report.valid)
        #expect(report.errors.contains { $0.code == .unsupportedAction })

        // Garbage and oversized input.
        #expect(throws: WorkflowError.self) { try WorkflowValidator.decode(Data("{not json".utf8)) }
        #expect(throws: WorkflowError.self) { try WorkflowValidator.decode(Data(repeating: 0x20, count: 600 * 1024)) }

        // Templates may only reference declared inputs; wrong schema versions are refused.
        var undeclared = Fixtures.notesWorkflow()
        undeclared.steps[1].value = "${password}"
        #expect(WorkflowValidator.validate(undeclared).errors.contains { $0.code == .invalidInput })
        var future = Fixtures.notesWorkflow()
        future.schemaVersion = 99
        #expect(!WorkflowValidator.validate(future).valid)

        // A coordinate-only step without explicit permission is invalid.
        var coords = Fixtures.notesWorkflow()
        coords.steps[2].target = ElementLocator(point: RelativePoint(x: 1, y: 1))
        #expect(WorkflowValidator.validate(coords).errors.contains { $0.code == .permissionDenied })

        // Symlinked files are not followed.
        let root = Fixtures.tempDir()
        let store = WorkflowStore(root: root)
        try store.save(Fixtures.notesWorkflow())
        let file = root.appendingPathComponent("definitions/save_note/r2.json")
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "/etc/hosts")
        #expect(throws: WorkflowError.self) { try store.load("save_note") }
    }

    @Test func publishingNeedsVerification() throws {
        let store = WorkflowStore(root: Fixtures.tempDir())
        var wf = Fixtures.notesWorkflow()
        wf.steps.removeLast()
        try store.save(wf)
        #expect(throws: WorkflowError.self) { try store.setStatus("save_note", .published) }
        #expect(try store.setStatus("save_note", .validated).status == .validated)
    }
}

@Suite struct FeedbackTests {
    func submission(_ summary: String = "Cannot scroll the nested pane in background") -> FeedbackSubmission {
        var s = FeedbackSubmission(category: .missingCapability, summary: summary)
        s.tool = "scroll"
        s.severity = .medium
        s.expected = "The pane scrolls without activation"
        s.actual = "No observable movement"
        s.wish = "A semantic scroll-container selector"
        s.reproSteps = ["get_app_state Mail", "scroll element 12 down"]
        return s
    }

    let env = FeedbackEnvironment(component: "wink-cua", version: "test")

    @Test func persistsDeduplicatesAndExports() throws {
        let root = Fixtures.tempDir().appendingPathComponent("feedback")
        let store = FeedbackStore(root: root)
        let first = try store.submit(self.submission(), environment: self.env)
        #expect(first.status == "created")
        var again = self.submission("cannot scroll the nested pane in background ")
        again.severity = .high
        again.reproSteps = ["different repro"]
        let second = try store.submit(again, environment: self.env)
        #expect(second.status == "merged")
        #expect(second.id == first.id)
        #expect(second.occurrences == 2)
        let report = try store.get(first.id)
        #expect(report.severity == .high)
        #expect(report.reproductions.count == 2)
        #expect(Fixtures.permissions(root) == 0o700)
        #expect(Fixtures.permissions(root.appendingPathComponent("\(first.id).json")) == 0o600)

        let markdown = store.export(format: "markdown")
        #expect(markdown.contains("Cannot scroll the nested pane"))
        let json = store.export(format: "json")
        #expect(json.contains(first.id))

        let other = try store.submit(self.submission("Paste loses the clipboard in Pages"), environment: self.env)
        #expect(other.status == "created")
        #expect(store.all().count == 2)
        try store.delete(other.id)
        #expect(store.all().count == 1)
        #expect(throws: WorkflowError.self) { try store.get("../../etc/passwd") }
    }

    @Test func redactsSecretsAndPersonalData() throws {
        let store = FeedbackStore(root: Fixtures.tempDir())
        var s = self.submission("Login fails with api_key=sk-live_abcdefghijklmnop1234 for levi@example.com")
        s.actual = "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U in /Users/levi/x"
        let result = try store.submit(s, environment: self.env)
        let raw = try String(contentsOf: store.root.appendingPathComponent("\(result.id).json"), encoding: .utf8)
        #expect(!raw.contains("sk-live"))
        #expect(!raw.contains("levi@example.com"))
        #expect(!raw.contains("eyJhbGci"))
        #expect(!raw.contains("/Users/levi"))
        #expect(raw.contains("[REDACTED"))
    }

    @Test func rateLimitsAndValidates() throws {
        let store = FeedbackStore(root: Fixtures.tempDir())
        store.rateLimit = (count: 2, seconds: 600)
        _ = try store.submit(self.submission("first problem with clicks"), environment: self.env)
        _ = try store.submit(self.submission("second problem with scrolls"), environment: self.env)
        do {
            _ = try store.submit(self.submission("third problem with typing"), environment: self.env)
            Issue.record("expected rate limit")
        } catch let e as WorkflowError {
            #expect(e.code == .rateLimited)
        }
        #expect(throws: WorkflowError.self) {
            try FeedbackStore(root: Fixtures.tempDir()).submit(self.submission("bad"), environment: self.env)
        }
    }

    @Test func retentionDropsOldReports() throws {
        let store = FeedbackStore(root: Fixtures.tempDir())
        _ = try store.submit(self.submission("an old problem nobody fixed"), environment: self.env)
        store.now = { Date().addingTimeInterval(100 * 86400) }
        _ = try store.submit(self.submission("a brand new problem today"), environment: self.env)
        #expect(store.all().map(\.summary) == ["a brand new problem today"])
    }

    @Test func diagnosticsCarryNoContent() {
        let log = DiagnosticLog(capacity: 3)
        for i in 0..<5 { log.record(tool: "click", app: "Mail", ok: i % 2 == 0, elapsedMs: i, message: "token=abc123secret") }
        let recent = log.recent(10)
        #expect(recent.count == 3)
        #expect(recent.allSatisfy { ($0.message ?? "").contains("abc123secret") == false })
    }
}
