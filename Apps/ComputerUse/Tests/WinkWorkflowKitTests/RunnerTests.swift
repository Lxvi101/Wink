import Foundation
import Testing
@testable import WinkWorkflowKit

@Suite struct RunnerTests {
    @Test func runsWithInputsAndVerifies() {
        let driver = Fixtures.notesDriver()
        let result = WorkflowRunner(driver: driver).run(Fixtures.notesWorkflow(), inputs: ["title": "Groceries"],
                                                        options: Fixtures.fastOptions())
        #expect(result.status == .succeeded, "\(result.message ?? "")")
        #expect(result.completedSteps == ["open", "title", "save", "verify"])
        #expect(driver.dispatched.map(\.action) == [.typeText, .click])
        #expect(driver.dispatched.first?.text == "Groceries")
        #expect(result.possibleCommit) // writes happened (and were verified)
        #expect(!result.retrySafe)

        // Same workflow, new input: the runtime resolves the UI again; nothing from the first run is reused.
        let second = Fixtures.notesDriver()
        let again = WorkflowRunner(driver: second).run(Fixtures.notesWorkflow(), inputs: ["title": "Taxes"],
                                                       options: Fixtures.fastOptions())
        #expect(again.status == .succeeded)
        #expect(second.elements[Fixtures.notes]!.contains { $0.value == "Saved: Taxes" })
    }

    @Test func ambiguousTargetRefusesWithoutClicking() {
        let driver = Fixtures.notesDriver()
        driver.elements[Fixtures.notes]!.append(Fixtures.button("Save", id: "save"))
        var wf = Fixtures.notesWorkflow()
        wf.steps.remove(at: 1) // only the click
        let result = WorkflowRunner(driver: driver).run(wf, inputs: ["title": "x"], options: Fixtures.fastOptions())
        #expect(result.status == .refused)
        #expect(result.code == .ambiguousTarget)
        #expect(driver.dispatched.isEmpty)
        #expect(!result.actionDispatched)
        #expect(result.retrySafe)
        #expect(result.diagnostics?.candidates?.count == 2)
        #expect(result.failedStepId == "save")
    }

    @Test func missingTargetFailsClosedWithDiagnostics() {
        let driver = Fixtures.notesDriver()
        driver.elements[Fixtures.notes]!.removeAll { $0.identifier == "save" }
        driver.elements[Fixtures.notes]!.append(Fixtures.button("Save Draft"))
        let result = WorkflowRunner(driver: driver).run(Fixtures.notesWorkflow(), inputs: ["title": "x"],
                                                        options: Fixtures.fastOptions())
        #expect(result.code == .targetNotFound)
        #expect(result.status == .failed) // the title was already typed
        #expect(result.possibleCommit)
        #expect(result.recovery != nil)
        #expect(result.diagnostics?.nearMisses?.isEmpty == false)
    }

    @Test func wrongApplicationIsRefused() {
        let driver = Fixtures.notesDriver()
        driver.reportedBundle[Fixtures.notes] = "com.evil.lookalike"
        let result = WorkflowRunner(driver: driver).run(Fixtures.notesWorkflow(), inputs: ["title": "x"],
                                                        options: Fixtures.fastOptions())
        #expect(result.code == .wrongApplication)
        #expect(result.status == .refused)
        #expect(driver.dispatched.isEmpty)
    }

    @Test func missingPermissionIsRefused() {
        let driver = Fixtures.notesDriver()
        driver.permissionGranted = false
        let result = WorkflowRunner(driver: driver).run(Fixtures.notesWorkflow(), inputs: ["title": "x"],
                                                        options: Fixtures.fastOptions())
        #expect(result.code == .permissionDenied)
        #expect(result.status == .refused)
        #expect(result.retrySafe)
    }

    @Test func failedPostconditionIsUncertainNotRetrySafe() {
        let driver = Fixtures.notesDriver()
        driver.effect = nil // the app ignores the click
        var wf = Fixtures.notesWorkflow()
        wf.steps[2].postconditions = [Condition(kind: .elementExists,
                                                target: ElementLocator(role: "AXStaticText", description: "status"))]
        let result = WorkflowRunner(driver: driver).run(wf, inputs: ["title": "x"], options: Fixtures.fastOptions())
        #expect(result.status == .uncertain)
        #expect(result.code == .postconditionFailed)
        #expect(result.actionDispatched)
        #expect(result.possibleCommit)
        #expect(!result.retrySafe)
    }

    @Test func driverErrorAfterDispatchIsUncertain() {
        let driver = Fixtures.notesDriver()
        driver.effect = { request, _ in
            if request.action == .click { throw WorkflowError(.dispatchFailed, "events lost", dispatched: true) }
        }
        let result = WorkflowRunner(driver: driver).run(Fixtures.notesWorkflow(), inputs: ["title": "x"],
                                                        options: Fixtures.fastOptions())
        #expect(result.code == .outcomeUncertain)
        #expect(result.status == .uncertain)
        #expect(result.possibleCommit)
    }

    @Test func foregroundCannotBeEscalated() {
        var wf = Fixtures.notesWorkflow()
        wf.steps[2].foreground = true
        // Not declared on the workflow: invalid.
        #expect(!WorkflowValidator.validate(wf).valid)
        // Declared, but the caller did not authorize it: refused before anything is sent.
        wf.requiresForeground = true
        let driver = Fixtures.notesDriver()
        let refused = WorkflowRunner(driver: driver).run(wf, inputs: ["title": "x"], options: Fixtures.fastOptions())
        #expect(refused.code == .permissionDenied)
        #expect(driver.dispatched.isEmpty)
        var options = Fixtures.fastOptions()
        options.allowForeground = true
        let allowed = WorkflowRunner(driver: driver).run(wf, inputs: ["title": "x"], options: options)
        #expect(allowed.status == .succeeded)
        #expect(driver.dispatched.last?.foreground == true)
    }

    @Test func secureFieldsOnlyTakeSecretInputs() {
        let bundle = Fixtures.notes
        let driver = MockDriver()
        driver.running = [bundle]
        driver.elements[bundle] = [Fixtures.field(placeholder: "Password", secure: true)]
        var step = WorkflowStep(id: "pw", action: .typeText)
        step.target = ElementLocator(role: "AXTextField", placeholder: "Password")
        step.value = "${pw}"
        var wf = Workflow(id: "login", name: "Login", bundleIds: [bundle], steps: [step], inputs: ["pw": InputSpec(type: .string)])
        let refused = WorkflowRunner(driver: driver).run(wf, inputs: ["pw": "hunter2"], options: Fixtures.fastOptions())
        #expect(refused.code == .permissionDenied)
        #expect(driver.dispatched.isEmpty)
        wf.inputs["pw"]?.secret = true
        let ok = WorkflowRunner(driver: driver).run(wf, inputs: ["pw": "hunter2"], options: Fixtures.fastOptions())
        #expect(ok.status == .succeeded)
        let json = WorkflowJSON.string(ok)
        #expect(!json.contains("hunter2"))
    }

    @Test func dryRunSendsNothing() {
        let driver = Fixtures.notesDriver()
        var options = Fixtures.fastOptions()
        options.dryRun = true
        let result = WorkflowRunner(driver: driver).run(Fixtures.notesWorkflow(), inputs: ["title": "x"], options: options)
        #expect(result.status == .dryRunPassed, "\(result.message ?? "")")
        #expect(driver.dispatched.isEmpty)
        #expect(result.steps.first { $0.id == "verify" }?.status == "not_yet_visible")
    }

    @Test func invalidInputsAreRejected() {
        let driver = Fixtures.notesDriver()
        let missing = WorkflowRunner(driver: driver).run(Fixtures.notesWorkflow(), inputs: [:], options: Fixtures.fastOptions())
        #expect(missing.code == .invalidInput)
        let unknown = WorkflowRunner(driver: driver).run(Fixtures.notesWorkflow(), inputs: ["title": "a", "evil": "b"],
                                                         options: Fixtures.fastOptions())
        #expect(unknown.code == .invalidInput)
        let wrongType = WorkflowRunner(driver: driver).run(Fixtures.notesWorkflow(), inputs: ["title": 5],
                                                           options: Fixtures.fastOptions())
        #expect(wrongType.code == .invalidInput)
        #expect(driver.dispatched.isEmpty)
    }

    @Test func disabledWorkflowsDoNotRun() {
        var wf = Fixtures.notesWorkflow()
        wf.status = .disabled
        let result = WorkflowRunner(driver: Fixtures.notesDriver()).run(wf, inputs: ["title": "x"], options: Fixtures.fastOptions())
        #expect(result.code == .workflowDisabled)
    }

    @Test func cancellationStopsBetweenSteps() {
        let driver = Fixtures.notesDriver()
        var options = Fixtures.fastOptions()
        let token = options.cancel
        driver.effect = { request, _ in if request.action == .typeText { token.cancel() } }
        options.cancel = token
        let result = WorkflowRunner(driver: driver).run(Fixtures.notesWorkflow(), inputs: ["title": "x"], options: options)
        #expect(result.status == .cancelled)
        #expect(result.code == .cancelled)
        #expect(driver.dispatched.count == 1)
        #expect(result.possibleCommit)
    }

    @Test func concurrentRunsAreSerialized() async {
        let driver = Fixtures.notesDriver()
        driver.dispatchDelayMs = 5
        let wf = Fixtures.notesWorkflow()
        let box = UnsafeSendableBox(driver)
        await withTaskGroup(of: RunStatus.self) { group in
            for i in 0..<4 {
                group.addTask {
                    WorkflowRunner(driver: box.value).run(wf, inputs: ["title": "n\(i)"], options: Fixtures.fastOptions()).status
                }
            }
            for await _ in group {}
        }
        #expect(!driver.sawConcurrentDispatch)
        #expect(driver.dispatched.count == 8)
    }

    @Test func staleHandleIsReResolvedOnce() {
        let driver = Fixtures.notesDriver()
        var staleOnce = true
        let original = driver.effect
        driver.effect = { request, d in
            if request.action == .click, staleOnce {
                staleOnce = false
                throw WorkflowError(.staleObservation, "element vanished")
            }
            try original?(request, d)
        }
        let result = WorkflowRunner(driver: driver).run(Fixtures.notesWorkflow(), inputs: ["title": "x"], options: Fixtures.fastOptions())
        #expect(result.status == .succeeded, "\(result.message ?? "")")
    }

    @Test func outputsAreRead() {
        let driver = Fixtures.notesDriver()
        var wf = Fixtures.notesWorkflow()
        wf.outputs = ["status": ElementLocator(role: "AXStaticText", description: "status")]
        let result = WorkflowRunner(driver: driver).run(wf, inputs: ["title": "Q3"], options: Fixtures.fastOptions())
        #expect(result.outputs?["status"] == "Saved: Q3")
    }
}

struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
