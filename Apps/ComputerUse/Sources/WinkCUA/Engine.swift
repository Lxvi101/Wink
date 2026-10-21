import AppKit
import ApplicationServices

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct ToolOutput {
    var text: String
    var image: Data?
    var isError = false
}

/// Per-app observation state. Indices are keyed by structural identity so an element keeps its number
/// for as long as it exists; diffs therefore only ever mention elements that actually changed.
final class AppSession {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let app: AXUIElement
    var snapshot: TreeSnapshot?
    var byIndex: [Int: UINode] = [:]
    var keyToIndex: [String: Int] = [:]
    var nextIndex = 1
    var windowID: CGWindowID?
    var windowSelector: String?
    /// Screenshot geometry from the latest capture: global origin of the window and pixels per point.
    var shotOrigin: CGPoint?
    var shotScale: CGFloat = 1

    init(app running: NSRunningApplication) {
        pid = running.processIdentifier
        name = running.localizedName ?? running.bundleIdentifier ?? "pid \(running.processIdentifier)"
        bundleID = running.bundleIdentifier
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2.0)
    }
}

final class Engine {
    private var sessions: [pid_t: AppSession] = [:]
    let capturer = WindowCapturer()
    var treeOptions = TreeOptions()

    // MARK: App resolution

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited && !$0.isTerminated }
    }

    func resolve(_ query: String, launch: Bool = true) throws -> NSRunningApplication {
        let q = query.trimmingCharacters(in: .whitespaces)
        let apps = runningApps()
        if let pid = Int32(q), let hit = apps.first(where: { $0.processIdentifier == pid }) { return hit }
        let lower = q.lowercased()
        if let hit = apps.first(where: { $0.bundleIdentifier?.lowercased() == lower })
            ?? apps.first(where: { $0.localizedName?.lowercased() == lower })
            ?? apps.first(where: { $0.activationPolicy == .regular && ($0.localizedName?.lowercased().hasPrefix(lower) ?? false) }) {
            return hit
        }
        guard launch, let url = applicationURL(for: q) else {
            throw ToolError("no running app matches '\(query)'. Use list_apps to see what is available.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var launched: NSRunningApplication?
        nonisolated(unsafe) var launchError: Error?
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            launched = app
            launchError = error
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 15)
        guard let app = launched else {
            throw ToolError("could not launch \(url.lastPathComponent): \(launchError.map { "\($0)" } ?? "timed out")")
        }
        // Give it a moment to put up a window.
        let deadline = Date().addingTimeInterval(6)
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        while Date() < deadline, AX.elements(ax, kAXWindowsAttribute).isEmpty { usleep(100_000) }
        return app
    }

    private func applicationURL(for query: String) -> URL? {
        if query.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) { return url }
        let name = query.hasSuffix(".app") ? query : "\(query).app"
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // Case-insensitive fallback.
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            if let hit = items.first(where: { $0.lowercased() == name.lowercased() }) {
                return URL(fileURLWithPath: dir).appendingPathComponent(hit)
            }
        }
        return nil
    }

    private func session(for query: String, launch: Bool = true) throws -> AppSession {
        let running = try resolve(query, launch: launch)
        if let existing = sessions[running.processIdentifier] { return existing }
        let created = AppSession(app: running)
        sessions[running.processIdentifier] = created
        return created
    }

    private func observedSession(_ query: String) throws -> AppSession {
        let s = try session(for: query, launch: false)
        guard s.snapshot != nil else {
            throw ToolError("call get_app_state for '\(s.name)' first; element indices come from it.")
        }
        return s
    }

    // MARK: list_apps

    func listApps() -> ToolOutput {
        var windowCounts: [pid_t: Int] = [:]
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in info where (w[kCGWindowLayer as String] as? Int) == 0 {
                if let pid = w[kCGWindowOwnerPID as String] as? Int32 { windowCounts[pid, default: 0] += 1 }
            }
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let lines = runningApps().filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            .map { app -> String in
                var line = "\(app.localizedName ?? "?") — \(app.bundleIdentifier ?? "no bundle id") pid=\(app.processIdentifier)"
                let count = windowCounts[app.processIdentifier, default: 0]
                line += " windows=\(count)"
                if app.processIdentifier == front { line += " [frontmost]" }
                if app.isHidden { line += " [hidden]" }
                return line
            }
        var text = "Running apps (\(lines.count)). Any installed app can also be named in get_app_state; it is launched in the background.\n"
        text += lines.joined(separator: "\n")
        if !AXIsProcessTrusted() {
            text += "\n\nWARNING: Accessibility permission is not granted to this process (or its host terminal)."
        }
        return ToolOutput(text: text)
    }

    // MARK: Observation

    private func chooseWindow(_ s: AppSession, selector: String?) -> AXUIElement? {
        func isWindow(_ el: AXUIElement) -> Bool {
            let role = AX.string(AX.attribute(el, kAXRoleAttribute))
            return role == "AXWindow" || role == "AXSheet" || role == "AXDrawer"
        }
        let windows = AX.elements(s.app, kAXWindowsAttribute).filter(isWindow)
        if let selector, !selector.isEmpty {
            if let n = Int(selector), n >= 0, n < windows.count { return windows[n] }
            let lower = selector.lowercased()
            if let hit = windows.first(where: { (AX.string(AX.attribute($0, kAXTitleAttribute)) ?? "").lowercased().contains(lower) }) {
                return hit
            }
        }
        return [AX.element(s.app, kAXFocusedWindowAttribute), AX.element(s.app, kAXMainWindowAttribute)]
            .compactMap { $0 }.first(where: isWindow) ?? windows.first
    }

    private func walk(_ s: AppSession) -> (TreeSnapshot, AXUIElement?) {
        let window = chooseWindow(s, selector: s.windowSelector)
        return (TreeWalker.walk(app: s.app, window: window, options: treeOptions), window)
    }

    /// Walk repeatedly until two consecutive walks agree (or the budget runs out). Returns the final walk.
    private func settledWalk(_ s: AppSession, budget: TimeInterval = 1.5) -> (TreeSnapshot, AXUIElement?) {
        usleep(45_000)
        var previous = walk(s)
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            usleep(55_000)
            let next = walk(s)
            if next.0.signature == previous.0.signature { return next }
            previous = next
        }
        return previous
    }

    private func render(_ s: AppSession, _ snap: TreeSnapshot, window: AXUIElement?, full: Bool) -> String {
        let windowChanged = snap.windowID != s.windowID || s.snapshot == nil
        if windowChanged { s.keyToIndex = [:]; s.nextIndex = 1 }
        var nodes = snap.nodes
        var byIndex: [Int: UINode] = [:]
        var keyToIndex: [String: Int] = [:]
        for i in nodes.indices {
            let index = s.keyToIndex[nodes[i].key] ?? { defer { s.nextIndex += 1 }; return s.nextIndex }()
            nodes[i].index = index
            byIndex[index] = nodes[i]
            keyToIndex[nodes[i].key] = index
        }
        let previous = s.snapshot
        s.keyToIndex = keyToIndex
        s.byIndex = byIndex
        s.windowID = snap.windowID
        var finalSnap = snap
        finalSnap.nodes = nodes
        s.snapshot = finalSnap

        var header = "App: \(s.name)"
        if let b = s.bundleID { header += " (\(b), pid \(s.pid))" }
        if let title = snap.windowTitle {
            header += "\nWindow: \"\(title)\""
            if let f = snap.windowFrame { header += " at \(Int(f.minX)),\(Int(f.minY)) size \(Int(f.width))x\(Int(f.height))" }
        } else if window == nil {
            header += "\nNo window (only the menu bar is available)."
        }
        let others = AX.elements(s.app, kAXWindowsAttribute).compactMap { AX.string(AX.attribute($0, kAXTitleAttribute)) }
            .filter { $0 != snap.windowTitle }
        if !others.isEmpty {
            header += "\nOther windows (pass window=\"<title>\"): " + others.prefix(8).map { "\"\($0)\"" }.joined(separator: ", ")
        }

        var footer = ""
        if let f = snap.focusedSummary { footer += "\nFocused: \(f)" }
        if let t = snap.selectedText { footer += "\nSelected text: \(t)" }
        if snap.truncated { footer += "\n(Tree truncated at \(treeOptions.maxNodes) elements; pass max_nodes to raise.)" }

        func line(_ n: UINode) -> String { String(repeating: "  ", count: n.depth) + "[\(n.index)] \(n.content)" }

        if !full, !windowChanged, let previous {
            let old = Dictionary(previous.nodes.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let newKeys = Set(nodes.map(\.key))
            var changes: [String] = []
            for n in nodes {
                if let o = old[n.key] {
                    if o.content != n.content { changes.append("~ " + line(n)) }
                } else {
                    changes.append("+ " + line(n))
                }
            }
            let removed = previous.nodes.filter { !newKeys.contains($0.key) }
            if !removed.isEmpty {
                let ids = removed.map { "\($0.index)" }
                changes.append("- removed: " + (ids.count > 40 ? ids.prefix(40).joined(separator: ",") + ",… (\(ids.count))" : ids.joined(separator: ",")))
            }
            if changes.isEmpty {
                return header + "\nNo UI changes since the last state; all indices still valid." + footer
            }
            if changes.count < max(12, nodes.count / 2) {
                return header + "\nChanges since last state (~ changed, + added, - removed; other indices unchanged):\n"
                    + changes.joined(separator: "\n") + footer
            }
        }
        return header + "\n" + nodes.map(line).joined(separator: "\n") + footer
    }

    private func screenshot(_ s: AppSession, window: AXUIElement?, maxDimension: CGFloat) -> (Data?, String) {
        guard let window, let id = AX.windowID(window) else { return (nil, "\nScreenshot: unavailable (no window).") }
        do {
            let shot = try capturer.capture(windowID: id, maxDimension: maxDimension, quality: 0.72)
            if let frame = AX.frame(window) { s.shotOrigin = frame.origin }
            s.shotScale = shot.scale
            return (shot.jpeg, "\nScreenshot: \(shot.pixelWidth)x\(shot.pixelHeight)px of the window (x/y arguments use these pixels).")
        } catch {
            return (nil, "\nScreenshot: unavailable (\(error)). Screen Recording permission may be missing.")
        }
    }

    static func screenIsLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) == true || (session?["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    func getAppState(_ args: [String: Any]) throws -> ToolOutput {
        if Self.screenIsLocked() {
            throw ToolError("the screen is locked, so app UI is not accessible. Unlock the Mac (or keep it unlocked) and retry.")
        }
        let s = try session(for: try args.string("app"))
        if let w = args["window"] { s.windowSelector = "\(w)" }
        var opts = treeOptions
        if let n = args.int("max_nodes") { opts.maxNodes = max(50, min(n, 20000)) }
        if let n = args.int("max_value_length") { opts.maxValueLength = max(20, n) }
        if let m = args["include_menu_bar"] as? Bool { opts.includeMenuBar = m }
        let saved = treeOptions
        treeOptions = opts
        defer { treeOptions = saved }
        let started = Date()
        let (snap, window) = walk(s)
        // Reading the window: the cursor stays put, so watchers learn where the window is instead.
        SessionEvents.shared.focus(window: snap.windowFrame.map { CGPoint(x: $0.midX, y: $0.midY) }, app: s)
        var text = render(s, snap, window: window, full: args.bool("full") ?? false)
        var image: Data?
        if args.bool("screenshot") ?? true {
            let (data, note) = screenshot(s, window: window, maxDimension: CGFloat(args.int("max_image_size") ?? 1400))
            image = data
            text += note
        }
        text += "\n(\(Int(Date().timeIntervalSince(started) * 1000)) ms)"
        return ToolOutput(text: text, image: image)
    }

    // MARK: Actions

    private func node(_ s: AppSession, _ args: [String: Any], key: String = "element_index") throws -> UINode? {
        guard let index = args.int(key) else { return nil }
        guard let node = s.byIndex[index] else {
            throw ToolError("element \(index) is not in the latest state of \(s.name); call get_app_state again.")
        }
        return node
    }

    private func center(_ node: UINode) throws -> CGPoint {
        guard let f = AX.frame(node.element) ?? node.frame, f.width > 0 || f.height > 0 else {
            throw ToolError("element \(node.index) has no on-screen frame; it may be hidden or scrolled away.")
        }
        return CGPoint(x: f.midX, y: f.midY)
    }

    private func screenPoint(_ s: AppSession, x: Double, y: Double) throws -> CGPoint {
        guard let origin = s.shotOrigin else {
            throw ToolError("x/y need a screenshot from get_app_state first (they are screenshot pixel coordinates).")
        }
        return CGPoint(x: origin.x + x / s.shotScale, y: origin.y + y / s.shotScale)
    }

    private func target(_ s: AppSession, _ args: [String: Any]) -> InputTarget {
        let fg = args.bool("foreground") ?? false
        if fg {
            NSRunningApplication(processIdentifier: s.pid)?.activate()
        } else if let window = s.windowID {
            KeyWindow.makeKey(pid: s.pid, windowID: window)
        }
        return InputTarget(pid: s.pid, windowID: s.windowID, foreground: fg)
    }

    private func showCursor(_ point: CGPoint, _ s: AppSession, _ effect: GhostCursor.Effect) {
        SessionEvents.shared.focus(cursor: point, app: s)
        let window = s.windowID
        DispatchQueue.main.async { MainActor.assumeIsolated { GhostCursor.shared.move(to: point, aboveWindow: window, effect: effect) } }
    }

    /// Run an action, then (by default) wait for the UI to settle and return the resulting diff.
    private func act(_ s: AppSession, _ args: [String: Any], _ body: () throws -> String) throws -> ToolOutput {
        let started = Date()
        let summary = try body()
        let actMs = Int(Date().timeIntervalSince(started) * 1000)
        guard args.bool("observe") ?? true else { return ToolOutput(text: "\(summary) (\(actMs) ms)") }
        let (snap, window) = settledWalk(s)
        var text = "\(summary) (\(actMs) ms)\n\n" + render(s, snap, window: window, full: false)
        var image: Data?
        if args.bool("screenshot") ?? false {
            let (data, note) = screenshot(s, window: window, maxDimension: CGFloat(args.int("max_image_size") ?? 1400))
            image = data
            text += note
        }
        text += "\n(total \(Int(Date().timeIntervalSince(started) * 1000)) ms)"
        return ToolOutput(text: text, image: image)
    }

    func click(_ args: [String: Any]) throws -> ToolOutput {
        let s = try observedSession(try args.string("app"))
        let button: CGMouseButton = switch (args["mouse_button"] as? String ?? "left").lowercased() {
        case "right": .right
        case "middle": .center
        default: .left
        }
        let count = max(1, min(args.int("click_count") ?? 1, 3))
        let effect: GhostCursor.Effect = button == .right ? .rightClick : (count > 1 ? .doubleClick : .click)
        let input = target(s, args)
        return try act(s, args) {
            if let n = try node(s, args) {
                let point = try? center(n)
                if let point { showCursor(point, s, effect) }
                if button == .left, count == 1, !input.foreground, n.actions.contains("AXPress") {
                    let err = AXUIElementPerformAction(n.element, kAXPressAction as CFString)
                    if err == .success { return "Clicked [\(n.index)] \(n.content) via accessibility press." }
                }
                if button == .right, !input.foreground, n.actions.contains("AXShowMenu"),
                   AXUIElementPerformAction(n.element, kAXShowMenuAction as CFString) == .success {
                    return "Opened the context menu of [\(n.index)] \(n.content)."
                }
                if ["AXTextField", "AXTextArea", "AXComboBox"].contains(n.role) {
                    AXUIElementSetAttributeValue(n.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                }
                guard let point else { throw ToolError("element \(n.index) has no frame and no press action.") }
                try Input.click(at: point, button: button, count: count, target: input)
                return "Clicked [\(n.index)] \(n.content) at \(Int(point.x)),\(Int(point.y)) with \(button == .left ? "left" : button == .right ? "right" : "middle") button x\(count)."
            }
            guard let x = args.double("x"), let y = args.double("y") else {
                throw ToolError("pass element_index, or x and y in screenshot pixels.")
            }
            let point = try screenPoint(s, x: x, y: y)
            showCursor(point, s, effect)
            try Input.click(at: point, button: button, count: count, target: input)
            return "Clicked at screenshot (\(Int(x)),\(Int(y))) = screen \(Int(point.x)),\(Int(point.y))."
        }
    }

    func typeText(_ args: [String: Any]) throws -> ToolOutput {
        let s = try observedSession(try args.string("app"))
        let text = try args.string("text")
        let input = target(s, args)
        return try act(s, args) {
            if let n = try node(s, args) {
                AXUIElementSetAttributeValue(n.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                if let p = try? center(n) { showCursor(p, s, .type) }
            } else if let focused = AX.element(s.app, kAXFocusedUIElementAttribute), let f = AX.frame(focused) {
                showCursor(CGPoint(x: f.midX, y: f.midY), s, .type)
            }
            try Input.type(text, target: input)
            return "Typed \(text.count) characters."
        }
    }

    func pressKey(_ args: [String: Any]) throws -> ToolOutput {
        let s = try observedSession(try args.string("app"))
        let key = try args.string("key")
        let input = target(s, args)
        return try act(s, args) {
            for chord in key.split(separator: " ").map(String.init) where !chord.isEmpty {
                try Input.press(chord, target: input)
                usleep(15_000)
            }
            return "Pressed \(key)."
        }
    }

    func setValue(_ args: [String: Any]) throws -> ToolOutput {
        let s = try observedSession(try args.string("app"))
        guard let n = try node(s, args) else { throw ToolError("element_index is required.") }
        let raw = try args.string("value")
        return try act(s, args) {
            if let p = try? center(n) { showCursor(p, s, .type) }
            let current = AX.attribute(n.element, kAXValueAttribute)
            let value: CFTypeRef = (current is NSNumber) ? (Double(raw).map { $0 as NSNumber } ?? raw as NSString) : raw as NSString
            let err = AXUIElementSetAttributeValue(n.element, kAXValueAttribute as CFString, value)
            guard err == .success else { throw ToolError("could not set value of [\(n.index)]: \(AX.errorDescription(err))") }
            return "Set [\(n.index)] to \"\(raw.prefix(80))\"."
        }
    }

    func performAction(_ args: [String: Any]) throws -> ToolOutput {
        let s = try observedSession(try args.string("app"))
        guard let n = try node(s, args) else { throw ToolError("element_index is required.") }
        let name = try args.string("action")
        let action = name.hasPrefix("AX") ? name : "AX" + name.prefix(1).uppercased() + name.dropFirst()
        return try act(s, args) {
            if let p = try? center(n) { showCursor(p, s, .click) }
            let err = AXUIElementPerformAction(n.element, action as CFString)
            guard err == .success else {
                throw ToolError("\(action) failed on [\(n.index)]: \(AX.errorDescription(err)). Available: \(n.actions.joined(separator: ", "))")
            }
            return "Performed \(action) on [\(n.index)] \(n.content)."
        }
    }

    func scroll(_ args: [String: Any]) throws -> ToolOutput {
        let s = try observedSession(try args.string("app"))
        let direction = (args["direction"] as? String ?? "down").lowercased()
        let pages = args.double("pages") ?? 1
        let input = target(s, args)
        return try act(s, args) {
            var point: CGPoint
            var height: CGFloat = 400
            var anchor: AXUIElement?
            if let n = try node(s, args) {
                point = try center(n)
                height = AX.frame(n.element)?.height ?? height
                anchor = n.element
            } else if let x = args.double("x"), let y = args.double("y") {
                point = try screenPoint(s, x: x, y: y)
                var hit: AXUIElement?
                if AXUIElementCopyElementAtPosition(s.app, Float(point.x), Float(point.y), &hit) == .success { anchor = hit }
            } else if let f = s.snapshot?.windowFrame {
                point = CGPoint(x: f.midX, y: f.midY)
                height = f.height
            } else {
                throw ToolError("pass element_index or x/y.")
            }
            showCursor(point, s, .scroll)
            // Background apps ignore synthetic wheel events, so scroll through the scroll bar's AX value.
            if !input.foreground, let moved = Self.scrollViaAccessibility(app: s, anchor: anchor, direction: direction, pages: pages) {
                return "Scrolled \(direction) \(pages) page(s) (scroll position \(moved))."
            }
            let amount = Int32(max(40, min(height * 0.85, 1200)) * pages)
            let steps = max(1, Int(amount / 120))
            let per = amount / Int32(steps)
            for _ in 0..<steps {
                switch direction {
                case "up": try Input.scroll(at: point, dx: 0, dy: per, target: input)
                case "left": try Input.scroll(at: point, dx: per, dy: 0, target: input)
                case "right": try Input.scroll(at: point, dx: -per, dy: 0, target: input)
                default: try Input.scroll(at: point, dx: 0, dy: -per, target: input)
                }
                usleep(12_000)
            }
            return "Scrolled \(direction) \(pages) page(s) with wheel events."
        }
    }

    /// Finds the scroll area containing `anchor` (or the largest one in the window) and moves its scroll bar.
    /// Returns a "from → to" description, or nil if no settable scroll bar was found.
    private static func scrollViaAccessibility(app s: AppSession, anchor: AXUIElement?, direction: String, pages: Double) -> String? {
        var area: AXUIElement?
        var cursor = anchor
        for _ in 0..<40 {
            guard let el = cursor else { break }
            if AX.string(AX.attribute(el, kAXRoleAttribute)) == "AXScrollArea" { area = el; break }
            cursor = AX.element(el, kAXParentAttribute)
        }
        if area == nil {
            func areaSize(_ n: UINode) -> CGFloat { (n.frame?.width ?? 0) * (n.frame?.height ?? 0) }
            let candidates = s.byIndex.values.filter { $0.role == "AXScrollArea" && $0.key.hasPrefix("W") }
            area = candidates.max { areaSize($0) < areaSize($1) }?.element
        }
        if area == nil, let win = AX.element(s.app, kAXFocusedWindowAttribute) {
            // Containers are flattened out of the rendered tree, so search the live window too.
            var queue = [win]
            var best: (AXUIElement, CGFloat)?
            var visited = 0
            while !queue.isEmpty, visited < 400 {
                let el = queue.removeFirst()
                visited += 1
                if AX.string(AX.attribute(el, kAXRoleAttribute)) == "AXScrollArea", let f = AX.frame(el) {
                    if f.width * f.height > (best?.1 ?? 0) { best = (el, f.width * f.height) }
                }
                queue.append(contentsOf: AX.elements(el, kAXChildrenAttribute))
            }
            area = best?.0
        }
        guard let area else { return nil }
        let vertical = direction == "up" || direction == "down"
        guard let bar = AX.element(area, vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute),
              AX.isSettable(bar, kAXValueAttribute),
              let current = (AX.attribute(bar, kAXValueAttribute) as? NSNumber)?.doubleValue,
              let areaFrame = AX.frame(area) else { return nil }
        let contents = AX.elements(area, kAXContentsAttribute).first ?? AX.elements(area, kAXChildrenAttribute).first
        let contentFrame = contents.flatMap(AX.frame) ?? areaFrame
        let visible = vertical ? areaFrame.height : areaFrame.width
        let total = vertical ? contentFrame.height : contentFrame.width
        let scrollable = max(total - visible, 1)
        let step = pages * Double(visible * 0.9 / scrollable)
        let sign: Double = (direction == "up" || direction == "left") ? -1 : 1
        let next = min(1, max(0, current + sign * step))
        guard AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, next as CFNumber) == .success else { return nil }
        return String(format: "%.2f → %.2f", current, next)
    }

    func drag(_ args: [String: Any]) throws -> ToolOutput {
        let s = try observedSession(try args.string("app"))
        let input = target(s, args)
        return try act(s, args) {
            let from: CGPoint, to: CGPoint
            if let a = try node(s, args, key: "from_index") { from = try center(a) } else {
                guard let x = args.double("from_x"), let y = args.double("from_y") else { throw ToolError("pass from_index or from_x/from_y.") }
                from = try screenPoint(s, x: x, y: y)
            }
            if let b = try node(s, args, key: "to_index") { to = try center(b) } else {
                guard let x = args.double("to_x"), let y = args.double("to_y") else { throw ToolError("pass to_index or to_x/to_y.") }
                to = try screenPoint(s, x: x, y: y)
            }
            showCursor(from, s, .drag(to: to))
            try Input.drag(from: from, to: to, target: input)
            return "Dragged from \(Int(from.x)),\(Int(from.y)) to \(Int(to.x)),\(Int(to.y))."
        }
    }

    func paste(_ args: [String: Any]) throws -> ToolOutput {
        let s = try observedSession(try args.string("app"))
        let text = try args.string("text")
        let input = target(s, args)
        return try act(s, args) {
            if let n = try node(s, args) {
                AXUIElementSetAttributeValue(n.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                if let p = try? center(n) { showCursor(p, s, .type) }
            }
            let board = NSPasteboard.general
            let saved = board.pasteboardItems?.map { item -> NSPasteboardItem in
                let copy = NSPasteboardItem()
                for type in item.types { if let d = item.data(forType: type) { copy.setData(d, forType: type) } }
                return copy
            } ?? []
            board.clearContents()
            board.setString(text, forType: .string)
            try Input.press("cmd+v", target: input)
            usleep(180_000)
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
            return "Pasted \(text.count) characters (clipboard restored)."
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) throws -> String {
        guard let v = self[key] else { throw ToolError("missing required argument '\(key)'.") }
        return v as? String ?? "\(v)"
    }

    func int(_ key: String) -> Int? {
        switch self[key] {
        case let n as NSNumber: n.intValue
        case let s as String: Int(s)
        default: nil
        }
    }

    func double(_ key: String) -> Double? {
        switch self[key] {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    func bool(_ key: String) -> Bool? {
        switch self[key] {
        case let n as NSNumber: n.boolValue
        case let s as String: ["true", "1", "yes"].contains(s.lowercased())
        default: nil
        }
    }
}
