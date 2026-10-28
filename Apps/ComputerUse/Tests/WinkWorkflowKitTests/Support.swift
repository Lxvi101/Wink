import Foundation
@testable import WinkWorkflowKit

/// A scriptable fake app: a list of elements per bundle id. Every observation renumbers the handles
/// (like wink-cua after a window change), so tests prove nothing depends on element indices.
final class MockDriver: WorkflowDriver {
    var elements: [String: [ElementObservation]] = [:]
    var windows: [String: WindowObservation] = [:]
    var running: Set<String> = []
    var launchable: Set<String> = []
    /// Bundle id reported by observations (to simulate a different app answering).
    var reportedBundle: [String: String] = [:]
    var permissionGranted = true
    var dispatched: [DispatchRequest] = []
    var observeCount = 0
    var handleBase = 1
    var effect: ((DispatchRequest, MockDriver) throws -> Void)?
    private var lastHandles: [Int: Int] = [:] // handle -> element position, for the latest observation
    private var concurrent = 0
    var sawConcurrentDispatch = false
    var dispatchDelayMs = 0

    func ensureApp(bundleId: String, launch: Bool) throws {
        guard self.permissionGranted else { throw WorkflowError(.permissionDenied, "Accessibility not granted") }
        if self.running.contains(bundleId) { return }
        guard launch else { throw WorkflowError(.appNotRunning, "\(bundleId) is not running") }
        guard self.launchable.contains(bundleId) else { throw WorkflowError(.appNotRunning, "cannot launch \(bundleId)") }
        self.running.insert(bundleId)
    }

    func observe(bundleId: String, window: WindowMatcher?, settle: Bool) throws -> UIObservation {
        guard self.permissionGranted else { throw WorkflowError(.permissionDenied, "Accessibility not granted") }
        guard self.running.contains(bundleId) else { throw WorkflowError(.appNotRunning, "\(bundleId) is not running") }
        self.observeCount += 1
        self.handleBase += 17 // indices change on every observation
        var list = self.elements[bundleId] ?? []
        self.lastHandles = [:]
        for i in list.indices {
            list[i].handle = self.handleBase + i
            self.lastHandles[list[i].handle] = i
        }
        return UIObservation(bundleId: self.reportedBundle[bundleId] ?? bundleId, pid: 42, appName: bundleId,
                             window: self.windows[bundleId] ?? WindowObservation(title: "Main"), elements: list)
    }

    func dispatch(_ request: DispatchRequest) throws -> String {
        self.concurrent += 1
        defer { self.concurrent -= 1 }
        if self.concurrent > 1 { self.sawConcurrentDispatch = true }
        if let e = request.element {
            guard self.lastHandles[e.handle] != nil else { throw WorkflowError(.staleObservation, "stale handle") }
        }
        if self.dispatchDelayMs > 0 { usleep(useconds_t(self.dispatchDelayMs * 1000)) }
        self.dispatched.append(request)
        try self.effect?(request, self)
        return "\(request.action.rawValue) ok"
    }

    // Helpers for effects
    func index(_ bundle: String, where match: (ElementObservation) -> Bool) -> Int? {
        self.elements[bundle]?.firstIndex(where: match)
    }
}

enum Fixtures {
    static let notes = "com.example.notes"

    static func button(_ title: String, id: String? = nil, ancestors: [AncestorLocator] = [],
                       frame: Rect = Rect(x: 10, y: 10, width: 80, height: 24)) -> ElementObservation {
        ElementObservation(handle: 0, role: "AXButton", identifier: id, title: title, actions: ["AXPress"], frame: frame,
                           ancestors: ancestors)
    }

    static func field(placeholder: String, value: String? = nil, secure: Bool = false) -> ElementObservation {
        ElementObservation(handle: 0, role: "AXTextField", subrole: secure ? "AXSecureTextField" : nil,
                           placeholder: placeholder, value: value, editable: true, secure: secure,
                           frame: Rect(x: 10, y: 50, width: 200, height: 22))
    }

    static func text(_ value: String, description: String? = nil) -> ElementObservation {
        ElementObservation(handle: 0, role: "AXStaticText", description: description, value: value,
                           frame: Rect(x: 10, y: 90, width: 200, height: 18))
    }

    /// A tiny notes app: type a title into the field, press Save, a "Saved: <title>" label appears.
    static func notesDriver() -> MockDriver {
        let d = MockDriver()
        d.running = [self.notes]
        d.elements[self.notes] = [
            self.button("New Note", id: "new-note"),
            self.field(placeholder: "Title"),
            self.button("Save", id: "save"),
        ]
        d.effect = { request, driver in
            switch request.action {
            case .typeText, .setValue:
                if let i = driver.index(self.notes, where: { $0.placeholder == "Title" }) {
                    driver.elements[self.notes]![i].value = request.text
                }
            case .click where request.element?.identifier == "save":
                let title = driver.elements[self.notes]!.first { $0.placeholder == "Title" }?.value ?? ""
                driver.elements[self.notes]!.append(self.text("Saved: \(title)", description: "status"))
            default: break
            }
        }
        return d
    }

    static func notesWorkflow() -> Workflow {
        var open = WorkflowStep(id: "open", action: .openApp)
        open.app = self.notes
        var type = WorkflowStep(id: "title", action: .typeText)
        type.target = ElementLocator(role: "AXTextField", placeholder: "Title")
        type.value = "${title}"
        var save = WorkflowStep(id: "save", action: .click)
        save.target = ElementLocator(role: "AXButton", identifier: "save", title: "Save")
        var verify = WorkflowStep(id: "verify", action: .waitFor)
        verify.condition = Condition(kind: .elementExists,
                                     target: ElementLocator(role: "AXStaticText", label: "Saved: ${title}"))
        verify.timeoutMs = 200
        return Workflow(id: "save_note", name: "Save a note", bundleIds: [self.notes],
                        steps: [open, type, save, verify], inputs: ["title": InputSpec(type: .string)])
    }

    static func fastOptions() -> RunOptions {
        var o = RunOptions()
        o.pollIntervalMs = 1
        o.defaultStepTimeoutMs = 50
        o.sleep = { _ in usleep(500) }
        return o
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wwk-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func permissions(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
