import AppKit

// wink-cua: a lean, Sky-style computer-use MCP server.
//   wink-cua            serve MCP over stdio (default)
//   wink-cua call <tool> '<json args>'   run one tool and print the result (debugging/benchmarks)
//   wink-cua permissions [request accessibility|screen-recording]   Wink's own grants, as JSON

Responsibility.disclaimIfNeeded()
let arguments = CommandLine.arguments.dropFirst()

if arguments.first == "permissions" {
    exit(Permissions.run(Array(arguments.dropFirst())))
} else if arguments.first == "call" {
    let rest = Array(arguments.dropFirst())
    guard let tool = rest.first else {
        FileHandle.standardError.write("usage: wink-cua call <tool> '<json>'\n".data(using: .utf8)!)
        exit(2)
    }
    let json = rest.count > 1 ? rest[1] : "{}"
    let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    let server = MCPServer()
    Thread.detachNewThread {
        let result = server.callTool(tool, args)
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
