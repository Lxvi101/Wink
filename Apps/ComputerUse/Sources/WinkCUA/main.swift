import AppKit

// wink-cua: a lean, Sky-style computer-use MCP server.
//   wink-cua            serve MCP over stdio (default)
//   wink-cua call <tool> '<json args>'   run one tool and print the result (debugging/benchmarks)
//   wink-cua permissions [request accessibility|screen-recording]   Wink's own grants, as JSON
//   wink-cua workflow list | get <id> | validate <id> | run <id> ['<inputs json>'] [--dry-run] | delete <id>
//   wink-cua feedback list | get <id> | delete <id> | export [markdown|json]

Responsibility.disclaimIfNeeded()
let arguments = CommandLine.arguments.dropFirst()

if arguments.first == "permissions" {
    exit(Permissions.run(Array(arguments.dropFirst())))
} else if let call = oneShotCall(Array(arguments)) {
    let server = MCPServer()
    Thread.detachNewThread {
        let result = server.callTool(call.0, call.1)
        for item in result["content"] as? [[String: Any]] ?? [] {
            if let text = item["text"] as? String { print(text) }
            if let data = item["data"] as? String { print("[image/jpeg \(data.count * 3 / 4) bytes]") }
        }
        // Let a cursor animation finish before exiting.
        usleep(UInt32((Double(ProcessInfo.processInfo.environment["WINK_CUA_LINGER"] ?? "0") ?? 0) * 1_000_000))
        SessionEvents.shared.end(reason: "exit")
        exit((result["isError"] as? Bool) == true ? 1 : 0)
    }
} else {
    let server = MCPServer()
    Thread.detachNewThread { server.run() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()

/// `call <tool> '<json>'` and the `workflow` / `feedback` shorthands, as (tool, arguments).
func oneShotCall(_ argv: [String]) -> (String, [String: Any])? {
    func usage(_ text: String) -> Never {
        FileHandle.standardError.write("usage: \(text)\n".data(using: .utf8)!)
        exit(2)
    }
    func json(_ text: String?) -> [String: Any] {
        guard let text else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            usage("arguments must be a JSON object")
        }
        return object
    }
    guard let command = argv.first else { return nil }
    let rest = Array(argv.dropFirst())
    switch command {
    case "call":
        guard let tool = rest.first else { usage("wink-cua call <tool> '<json>'") }
        return (tool, json(rest.count > 1 ? rest[1] : nil))
    case "workflow":
        let words = rest.filter { !$0.hasPrefix("--") }
        let help = "wink-cua workflow list | get <id> | validate <id> | run <id> ['<inputs json>'] [--dry-run] | delete <id>"
        switch words.first {
        case "list": return ("workflow_list", [:])
        case "get", "validate", "delete":
            guard words.count > 1 else { usage(help) }
            return ("workflow_\(words[0])", ["id": words[1]])
        case "run":
            guard words.count > 1 else { usage(help) }
            var args: [String: Any] = ["id": words[1], "inputs": json(words.count > 2 ? words[2] : nil)]
            if rest.contains("--dry-run") { args["dry_run"] = true }
            if rest.contains("--allow-foreground") { args["allow_foreground"] = true }
            return ("workflow_run", args)
        default: usage(help)
        }
    case "feedback":
        let help = "wink-cua feedback list | get <id> | delete <id> | export [markdown|json]"
        switch rest.first {
        case "list": return ("feedback_list", [:])
        case "get", "delete":
            guard rest.count > 1 else { usage(help) }
            return ("feedback_\(rest[0])", ["id": rest[1]])
        case "export": return ("feedback_export", ["format": rest.count > 1 ? rest[1] : "markdown"])
        default: usage(help)
        }
    default:
        return nil
    }
}
