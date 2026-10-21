//
//  MCPCommand.swift
//  WinkCLI
//

import Commander
import Foundation
import WinkCore

/// Entry point for Model Context Protocol related subcommands.
@MainActor
struct MCPCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "mcp",
        abstract: "Model Context Protocol server operations",
        discussion: """
        The MCP command runs Wink as an MCP server, exposing its tools to AI clients
        like Codex, Claude Code, and Cursor.

        EXAMPLES:
          wink mcp                          # Start MCP server on stdio
          wink mcp serve                     # Explicitly start MCP server
          wink mcp serve --transport stdio   # Explicitly select stdio transport
        """,
        subcommands: [
            Serve.self,
        ],
        defaultSubcommand: Serve.self,
        showHelpOnEmptyInvocation: false
    )
}
