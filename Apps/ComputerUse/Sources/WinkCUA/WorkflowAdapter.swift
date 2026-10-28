import AppKit
import ApplicationServices
import WinkWorkflowKit

/// Converts wink-cua's walked tree into WinkWorkflowKit's normalized observations. Uses the typed AX
/// attributes kept on UINode, never the rendered `content` line.
enum CUAObservation {
    static func element(_ n: UINode, windowOrigin: CGPoint?) -> ElementObservation {
        let frame = n.frame.map { f -> Rect in
            let o = windowOrigin ?? .zero
            return Rect(x: f.minX - o.x, y: f.minY - o.y, width: f.width, height: f.height)
        }
        let region = n.key.hasPrefix("M") ? "menu_bar" : n.key.hasPrefix("P") ? "popup" : "window"
        return ElementObservation(
            handle: n.index, role: n.role, subrole: n.subrole, identifier: n.identifier, title: n.title,
            description: n.desc, placeholder: n.placeholder, value: n.value.map { String($0.prefix(4000)) },
            enabled: n.enabled, focused: n.focused, editable: n.editable, secure: n.secure, selected: n.selected,
            actions: n.actions, frame: frame, ancestors: n.ancestors, region: region)
    }

    static func make(_ s: AppSession) -> UIObservation {
        let snap = s.snapshot
        let origin = snap?.windowFrame?.origin
        let window = snap.map { snap -> WindowObservation? in
            guard snap.windowTitle != nil || snap.windowFrame != nil else { return nil }
            return WindowObservation(title: snap.windowTitle, frame: snap.windowFrame.map {
                Rect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)
            })
        } ?? nil
        return UIObservation(bundleId: s.bundleID, pid: s.pid, appName: s.name, window: window,
                             elements: (snap?.nodes ?? []).map { self.element($0, windowOrigin: origin) },
                             truncated: snap?.truncated ?? false)
    }
}

/// Runs workflow steps through the same Engine paths the MCP tools use (AX press, background input,
/// KeyWindow, …), so replay has exactly the agent tools' behaviour and authority.
final class CUAWorkflowDriver: WorkflowDriver {
    let engine: Engine
    private var savedSelectors: [pid_t: String?] = [:]

    init(engine: Engine) {
        self.engine = engine
    }

    private func preflight() throws {
        guard AXIsProcessTrusted() else {
            SessionEvents.shared.permissionNeeded("accessibility")
            throw WorkflowError(.permissionDenied, Engine.permissionAdvice("Accessibility"))
        }
        if Engine.screenIsLocked() {
            throw WorkflowError(.requiresUserInteraction, "the screen is locked, so app UI is not accessible")
        }
    }

    private func running(_ bundleId: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first { !$0.isTerminated }
    }

    func ensureApp(bundleId: String, launch: Bool) throws {
        try self.preflight()
        if self.running(bundleId) != nil { return }
        guard launch else { throw WorkflowError(.appNotRunning, "\(bundleId) is not running") }
        do {
            let app = try self.engine.resolve(bundleId, launch: true)
            guard app.bundleIdentifier?.lowercased() == bundleId.lowercased() else {
                throw WorkflowError(.wrongApplication, "launching \(bundleId) produced \(app.bundleIdentifier ?? "an app without bundle id")")
            }
        } catch let error as ToolError {
            throw WorkflowError(.appNotRunning, error.description)
        }
    }

    func observe(bundleId: String, window: WindowMatcher?, settle: Bool) throws -> UIObservation {
        try self.preflight()
        guard let app = self.running(bundleId) else { throw WorkflowError(.appNotRunning, "\(bundleId) is not running") }
        let s: AppSession
        do {
            s = try self.engine.session(for: "\(app.processIdentifier)", launch: false)
        } catch {
            throw WorkflowError(.appNotRunning, "\(error)")
        }
        guard s.bundleID == app.bundleIdentifier else {
            throw WorkflowError(.wrongApplication, "pid \(s.pid) is \(s.bundleID ?? "unknown"), not \(bundleId)")
        }
        if self.savedSelectors[s.pid] == nil { self.savedSelectors[s.pid] = .some(s.windowSelector) }
        s.windowSelector = window?.title ?? window?.titleContains
        let (snap, element) = settle ? self.engine.settledWalk(s, budget: 1.0) : self.engine.walk(s)
        // Rendering keeps the session's index map coherent, so the agent's own indices stay valid.
        self.engine.render(s, snap, window: element, full: false)
        return CUAObservation.make(s)
    }

    func dispatch(_ r: DispatchRequest) throws -> String {
        try self.preflight()
        guard let s = self.engine.sessions[r.pid], s.bundleID == r.bundleId,
              NSRunningApplication(processIdentifier: r.pid)?.isTerminated == false else {
            throw WorkflowError(.staleObservation, "\(r.bundleId) (pid \(r.pid)) is no longer the observed process")
        }
        var args: [String: Any] = ["app": "\(r.pid)", "observe": false, "foreground": r.foreground]
        if let e = r.element {
            guard let node = s.byIndex[e.handle], node.role == e.role else {
                throw WorkflowError(.staleObservation, "the resolved element changed before it could be used")
            }
            args[r.action == .drag ? "from_index" : "element_index"] = e.handle
        }
        if let e = r.toElement { args["to_index"] = e.handle }
        if let b = r.mouseButton { args["mouse_button"] = b }
        if let c = r.clickCount { args["click_count"] = c }
        self.engine.dispatchState = .none
        do {
            let output: ToolOutput
            switch r.action {
            case .click:
                if r.element == nil, let p = r.point {
                    guard let origin = s.snapshot?.windowFrame?.origin else {
                        throw WorkflowError(.targetNotFound, "no window frame for the coordinate fallback")
                    }
                    output = try self.engine.click(s, screenPoint: CGPoint(x: origin.x + p.x, y: origin.y + p.y), args: args)
                } else {
                    output = try self.engine.click(args)
                }
            case .typeText:
                args["text"] = r.text ?? ""
                output = try self.engine.typeText(args)
            case .paste:
                args["text"] = r.text ?? ""
                output = try self.engine.paste(args)
            case .setValue:
                args["value"] = r.text ?? ""
                output = try self.engine.setValue(args)
            case .pressKey:
                args["key"] = r.key ?? ""
                output = try self.engine.pressKey(args)
            case .performAction:
                args["action"] = r.axAction ?? ""
                output = try self.engine.performAction(args)
            case .scroll:
                args["direction"] = r.direction ?? "down"
                args["pages"] = r.pages ?? 1
                output = try self.engine.scroll(args)
            case .drag:
                output = try self.engine.drag(args)
            case .openApp, .selectWindow, .waitFor, .assert:
                throw WorkflowError(.unsupportedAction, "\(r.action.rawValue) is not dispatched as input")
            }
            return String(output.text.split(separator: "\n").first ?? "")
        } catch let error as WorkflowError {
            throw error
        } catch let error as ToolError {
            let dispatched = !error.notDispatched && self.engine.dispatchState != .none
            let stale = error.notDispatched && error.description.contains("not in the latest state")
            throw WorkflowError(stale ? .staleObservation : .dispatchFailed, error.description, dispatched: dispatched)
        } catch {
            throw WorkflowError(.dispatchFailed, "\(error)", dispatched: self.engine.dispatchState != .none)
        }
    }

    /// Puts back the window selectors the agent had chosen before the run.
    func restore() {
        for (pid, selector) in self.savedSelectors { self.engine.sessions[pid]?.windowSelector = selector }
        self.savedSelectors = [:]
    }
}

/// Captures agent actions at the tool boundary while a recording is active: the resolved element's typed
/// attributes before the action, and the settled diff the action already produced afterwards.
struct RecordingCapture {
    var action: RecordedAction
    let started = Date()
    /// Text the recording redacted; kept in memory only, to scrub it from the evidence afterwards.
    var redactedText: String?

    static let recordable: [String: StepAction] = [
        "click": .click, "type_text": .typeText, "paste": .paste, "set_value": .setValue, "press_key": .pressKey,
        "perform_action": .performAction, "scroll": .scroll, "drag": .drag,
    ]

    static func before(tool: String, args: [String: Any], engine: Engine, recorder: WorkflowRecorder) -> RecordingCapture? {
        guard let kind = self.recordable[tool], let appArg = args["app"] else { return nil }
        guard let s = try? engine.session(for: "\(appArg)", launch: false),
              let wants = recorder.wants(bundleId: s.bundleID) else { return nil }
        var a = RecordedAction(seq: wants.seq, tool: tool, action: kind, bundleId: s.bundleID)
        let origin = s.snapshot?.windowFrame?.origin
        a.window = WindowContext(
            title: s.snapshot?.windowTitle.map { Redactor.sanitize($0, limit: 120) }, role: "AXWindow",
            frame: s.snapshot?.windowFrame.map { Rect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) })

        func describe(index key: String, x xKey: String, y yKey: String) -> (ElementLocator?, RelativePoint?, ElementObservation?) {
            if let index = args.int(key), let node = s.byIndex[index] {
                let element = CUAObservation.element(node, windowOrigin: origin)
                return (LocatorBuilder.locator(for: element), nil, element)
            }
            guard let x = args.double(xKey), let y = args.double(yKey),
                  let point = try? engine.screenPoint(s, x: x, y: y) else { return (nil, nil, nil) }
            let relative = origin.map { RelativePoint(x: point.x - $0.x, y: point.y - $0.y) }
            if let node = self.hitNode(s, point) {
                let element = CUAObservation.element(node, windowOrigin: origin)
                var locator = LocatorBuilder.locator(for: element)
                locator.point = relative
                return (locator, relative, element)
            }
            return (nil, relative, nil)
        }

        var redacted: String?
        let primary = kind == .drag ? describe(index: "from_index", x: "from_x", y: "from_y")
            : describe(index: "element_index", x: "x", y: "y")
        a.target = primary.0
        a.point = primary.1
        a.targetSummary = primary.2?.summary
        a.targetSecure = primary.2?.secure ?? false
        if kind == .drag { a.toTarget = describe(index: "to_index", x: "to_x", y: "to_y").0 }

        if let text = (kind == .setValue ? args["value"] : args["text"]).map({ "\($0)" }) {
            var secure = a.targetSecure
            if primary.2 == nil, let focused = AX.element(s.app, kAXFocusedUIElementAttribute) {
                secure = AX.string(AX.attribute(focused, kAXSubroleAttribute)) == "AXSecureTextField"
            }
            a.targetSecure = secure
            a.text = RecordedText.capture(text, secureTarget: secure, captureText: wants.captureText)
            if a.text?.redacted == true { redacted = text }
        }
        a.key = args["key"] as? String
        a.axAction = args["action"] as? String
        a.direction = args["direction"] as? String
        a.pages = args.double("pages")
        a.mouseButton = args["mouse_button"] as? String
        a.clickCount = args.int("click_count")
        a.foreground = args.bool("foreground") ?? false
        return RecordingCapture(action: a, redactedText: redacted)
    }

    /// A select_window step when the agent explicitly chose a window with get_app_state.
    static func windowSelection(args: [String: Any], engine: Engine, recorder: WorkflowRecorder) -> RecordedAction? {
        guard let window = args["window"], let appArg = args["app"],
              let s = try? engine.session(for: "\(appArg)", launch: false),
              let wants = recorder.wants(bundleId: s.bundleID) else { return nil }
        var a = RecordedAction(seq: wants.seq, tool: "get_app_state", action: .selectWindow, bundleId: s.bundleID)
        a.windowSelector = "\(window)"
        a.dispatched = false
        a.outcome = "no_change"
        return a
    }

    func finish(engine: Engine, error: Error?, isError: Bool) -> RecordedAction {
        var a = self.action
        a.elapsedMs = Int(Date().timeIntervalSince(self.started) * 1000)
        let failed = error != nil || isError
        a.status = failed ? "error" : "ok"
        if let toolError = error as? ToolError, toolError.notDispatched {
            a.dispatched = false
        } else {
            a.dispatched = engine.dispatchState != .none
        }
        if let error { a.error = Redactor.sanitize("\(error)", limit: 300) }
        if let ev = engine.lastEvidence, !failed {
            let origin = ev.window?.origin
            var before: [String: ElementObservation] = [:]
            for n in ev.before { before[n.key] = CUAObservation.element(n, windowOrigin: origin) }
            let after = ev.after.map { (key: $0.key, element: CUAObservation.element($0, windowOrigin: origin)) }
            var evidence = ActionEvidence.diff(before: before, after: after, windowTitle: nil)
            if let secret = self.redactedText { evidence = evidence.scrubbing(secret) }
            a.evidence = evidence
            a.outcome = evidence.added + evidence.changed + evidence.removed > 0 ? "observed_change" : "no_change"
        } else {
            a.outcome = failed ? "failed" : "unobserved"
        }
        return a
    }

    /// Maps a screen point to the observed node under it (walking up from the hit element).
    static func hitNode(_ s: AppSession, _ point: CGPoint) -> UINode? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(s.app, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        let nodes = Array(s.byIndex.values)
        for _ in 0..<8 {
            if let node = nodes.first(where: { CFEqual($0.element, element) }) { return node }
            guard let parent = AX.element(element, kAXParentAttribute) else { break }
            element = parent
        }
        return nil
    }
}
