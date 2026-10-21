import Foundation

/// Minimal MCP (JSON-RPC 2.0 over newline-delimited stdio). Requests are handled one at a time on a
/// dedicated thread so the main thread stays free for the cursor overlay.
final class MCPServer {
    private let engine = Engine()
    private let out = FileHandle.standardOutput

    static let instructions = """
    Wink Computer Use: drive any macOS app in the background without taking over the user's mouse or keyboard.
    Loop: get_app_state(app) -> act with element indices -> read the diff returned by the action.
    - Every action returns the settled UI diff (pass observe=false to skip). You rarely need to call get_app_state again.
    - Element indices are stable while an element exists; unchanged elements keep their numbers across diffs.
    - Prefer element_index over x/y. x/y are pixels in the latest screenshot of that app.
    - type_text types into the focused element (pass element_index to focus a field first); paste is faster for long text.
    - press_key uses chords like "cmd+s", "shift+Tab", "Return"; space-separate several chords.
    - Pass foreground=true only when an app ignores background input; it activates the app and moves the real pointer.
    """

    private var tools: [[String: Any]] {
        func schema(_ props: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "object", "properties": props, "required": required]
        }
        let app: [String: Any] = ["type": "string", "description": "App name, bundle id or pid"]
        let idx: [String: Any] = ["type": "integer", "description": "Element index from the app state"]
        let observe: [String: Any] = ["type": "boolean", "description": "Return the settled UI diff after acting (default true)"]
        let shot: [String: Any] = ["type": "boolean", "description": "Attach a window screenshot to the result (default false)"]
        let fg: [String: Any] = ["type": "boolean", "description": "Activate the app and use real HID input (default false = background)"]
        let num: [String: Any] = ["type": "number"]
        return [
            ["name": "list_apps", "description": "List running apps with bundle ids, pids and window counts.",
             "inputSchema": schema([:], [])],
            ["name": "get_app_state",
             "description": "Accessibility tree of the app's focused window (plus menu bar) with element indices, and a screenshot. Repeated calls return only what changed.",
             "inputSchema": schema([
                 "app": app,
                 "window": ["type": "string", "description": "Window title substring or index (default: focused window)"],
                 "screenshot": ["type": "boolean", "description": "Attach a screenshot (default true)"],
                 "full": ["type": "boolean", "description": "Return the full tree instead of a diff"],
                 "max_nodes": ["type": "integer", "description": "Element cap (default 1500)"],
                 "max_value_length": ["type": "integer", "description": "Truncate long values (default 400)"],
                 "include_menu_bar": ["type": "boolean", "description": "Include the menu bar (default true)"],
                 "max_image_size": ["type": "integer", "description": "Longest screenshot edge in pixels (default 1400)"],
             ], ["app"])],
            ["name": "click", "description": "Click an element (accessibility press when possible) or screenshot coordinates.",
             "inputSchema": schema([
                 "app": app, "element_index": idx, "x": num, "y": num,
                 "mouse_button": ["type": "string", "enum": ["left", "right", "middle"]],
                 "click_count": ["type": "integer", "description": "1-3"],
                 "foreground": fg, "observe": observe, "screenshot": shot,
             ], ["app"])],
            ["name": "type_text", "description": "Type text into the focused element, or into element_index after focusing it.",
             "inputSchema": schema(["app": app, "text": ["type": "string"], "element_index": idx, "foreground": fg,
                                    "observe": observe, "screenshot": shot], ["app", "text"])],
            ["name": "paste", "description": "Insert text via the clipboard (restored afterwards). Best for long text.",
             "inputSchema": schema(["app": app, "text": ["type": "string"], "element_index": idx, "foreground": fg,
                                    "observe": observe, "screenshot": shot], ["app", "text"])],
            ["name": "press_key", "description": "Press key chords, e.g. \"cmd+s\", \"Return\", \"shift+Tab\", \"cmd+a Delete\".",
             "inputSchema": schema(["app": app, "key": ["type": "string"], "foreground": fg, "observe": observe,
                                    "screenshot": shot], ["app", "key"])],
            ["name": "set_value", "description": "Set an element's value directly (text fields, sliders, steppers).",
             "inputSchema": schema(["app": app, "element_index": idx, "value": ["type": "string"], "observe": observe,
                                    "screenshot": shot], ["app", "element_index", "value"])],
            ["name": "perform_action", "description": "Run a secondary accessibility action listed on the element (e.g. Raise, ShowMenu, Increment).",
             "inputSchema": schema(["app": app, "element_index": idx, "action": ["type": "string"], "observe": observe,
                                    "screenshot": shot], ["app", "element_index", "action"])],
            ["name": "scroll", "description": "Scroll an element, a screenshot point, or the window center.",
             "inputSchema": schema([
                 "app": app, "element_index": idx, "x": num, "y": num,
                 "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                 "pages": ["type": "number", "description": "Default 1"], "foreground": fg, "observe": observe, "screenshot": shot,
             ], ["app", "direction"])],
            ["name": "drag", "description": "Drag between elements (from_index/to_index) or screenshot points.",
             "inputSchema": schema([
                 "app": app, "from_index": idx, "to_index": idx, "from_x": num, "from_y": num, "to_x": num, "to_y": num,
                 "foreground": fg, "observe": observe, "screenshot": shot,
             ], ["app"])],
        ]
    }

    func run() {
        engine.capturer.prewarm()
        SessionEvents.shared.endOnTermination()
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            guard let id else { continue } // notifications need no reply
            switch method {
            case "initialize":
                let version = params["protocolVersion"] as? String ?? "2025-06-18"
                reply(id, [
                    "protocolVersion": version,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "wink-cua", "version": "0.2.0"],
                    "instructions": Self.instructions,
                ])
            case "ping":
                reply(id, [:])
            case "tools/list":
                reply(id, ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                reply(id, callTool(name, args))
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found: \(method)"]])
            }
        }
        SessionEvents.shared.end(reason: "exit")
        exit(0)
    }

    func callTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
        let output: ToolOutput
        if name != "list_apps" { SessionEvents.shared.toolStarted(name, app: args["app"].map { "\($0)" }) }
        defer { if name != "list_apps" { SessionEvents.shared.toolFinished() } }
        do {
            switch name {
            case "list_apps": output = engine.listApps()
            case "get_app_state": output = try engine.getAppState(args)
            case "click": output = try engine.click(args)
            case "type_text": output = try engine.typeText(args)
            case "paste": output = try engine.paste(args)
            case "press_key": output = try engine.pressKey(args)
            case "set_value": output = try engine.setValue(args)
            case "perform_action": output = try engine.performAction(args)
            case "scroll": output = try engine.scroll(args)
            case "drag": output = try engine.drag(args)
            default: output = ToolOutput(text: "unknown tool \(name)", isError: true)
            }
        } catch {
            output = ToolOutput(text: "Error: \(error)", isError: true)
        }
        var content: [[String: Any]] = [["type": "text", "text": output.text]]
        if let image = output.image {
            content.append(["type": "image", "data": image.base64EncodedString(), "mimeType": "image/jpeg"])
        }
        return ["content": content, "isError": output.isError]
    }

    private func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        out.write(data)
    }
}
