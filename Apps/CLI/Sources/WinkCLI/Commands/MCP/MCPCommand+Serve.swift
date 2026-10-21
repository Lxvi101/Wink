//
//  MCPCommand+Serve.swift
//  WinkCLI
//

import Commander
import Darwin
import Logging
import WinkCore

extension MCPCommand {
    /// Start MCP server
    @MainActor
    struct Serve {
        static let commandDescription = CommandDescription(
            commandName: "serve",
            abstract: "Start Wink as an MCP server",
            discussion: """
            Starts Wink as an MCP server, exposing all its tools via the
            Model Context Protocol. This allows AI clients like Claude to use
            Wink's automation capabilities. The server is background-only by default;
            pass --allow-foreground to authorize foreground actions and browser user activation for this server process.
            --allow-temporary-clipboard separately permits bounded temporary paste to exact snapshots without
            authorizing foreground UI or persistent clipboard writes.

            USAGE WITH CLAUDE CODE:
              claude mcp add wink -- wink mcp

            USAGE WITH MCP INSPECTOR:
              npx @modelcontextprotocol/inspector wink mcp serve
            """
        )

        @Option(help: "Transport type (stdio; HTTP/SSE are reserved but not implemented)")
        var transport: String = "stdio"

        @Option(help: "Reserved port for future HTTP/SSE transport support")
        var port: Int = 8080

        @Flag(
            name: .customLong("allow-foreground"),
            help: "Authorize foreground/global UI and browser user activation for this MCP server"
        )
        var allowForeground = false

        @Flag(
            name: .customLong("allow-temporary-clipboard"),
            help: "Allow bounded temporary clipboard paste to exact snapshots; UI remains background-only"
        )
        var allowTemporaryClipboard = false

        var browserHandoff: String?
        var runtimeOptions = CommandRuntimeOptions()

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            var localDaemon: WinkDaemon?
            do {
                guard let transportType = Self.transportType(named: self.transport) else {
                    runtime.logger.setJsonOutputMode(runtime.configuration.jsonOutput)
                    let message = "Invalid transport '\(self.transport)'. Use stdio, http, or sse."
                    if runtime.configuration.jsonOutput {
                        outputError(message: message, code: .INVALID_ARGUMENT, logger: runtime.logger)
                    } else {
                        fputs("Error: \(message)\n", stderr)
                    }
                    throw ExitCode.failure
                }

                guard transportType == .stdio else {
                    runtime.logger.setJsonOutputMode(runtime.configuration.jsonOutput)
                    let message = "Transport '\(self.transport)' is not implemented. Use stdio."
                    if runtime.configuration.jsonOutput {
                        outputError(message: message, code: .VALIDATION_ERROR, logger: runtime.logger)
                    } else {
                        fputs("Error: \(message)\n", stderr)
                    }
                    throw ExitCode.failure
                }

                if runtime.services is RemoteWinkServices {
                    runtime.logger.debug("MCP: using remote Bridge host; skipping local daemon startup")
                } else {
                    let daemon = WinkDaemon(configuration: .embeddedMCP())
                    localDaemon = daemon
                    try await daemon.startChecked()
                }

                let mutationCoordinator = runtime.toolSnapshotMutationCoordinator
                let toolContext = Self.makeToolContext(
                    services: runtime.services,
                    snapshotMutationCoordinator: mutationCoordinator,
                    executionAuthority: MCPToolExecutionAuthority(
                        basePolicy: self.allowForeground ? .foregroundAllowed : .backgroundOnly,
                        temporaryClipboardPasteGranted: self.allowTemporaryClipboard
                    ),
                    capturePreflightRefusal: runtime.toolCapturePreflightRefusal
                )
                let browserHandoff = runtime.browserHandoffReceiptBundleData.map {
                    BrowserMCPHandoffGrant(payload: $0)
                }
                // Server initialization opens the authenticated remote scope before tools are registered or served.
                let server = try await WinkMCPServer(
                    toolContext: toolContext,
                    browserHandoff: browserHandoff
                )
                try await server.serve(transport: transportType, port: self.port)
                await Self.stopLocalDaemon(localDaemon)
            } catch let exitCode as ExitCode {
                await Self.stopLocalDaemon(localDaemon)
                throw exitCode
            } catch {
                await Self.stopLocalDaemon(localDaemon)
                runtime.logger.error("Failed to start MCP server: \(error)")
                throw ExitCode.failure
            }
        }

        func validateBeforeRuntime() throws {
            if self.browserHandoff != nil {
                guard self.runtimeOptions.browserHandoffReceiptBundleData != nil else {
                    throw BrowserHandoffCLIInputError.invalidReceipt("receipt was not loaded before runtime creation")
                }
                guard self.runtimeOptions.preferRemote,
                      !self.runtimeOptions.remoteIsolationRequested,
                      self.runtimeOptions.bridgeSocketPath != nil
                else {
                    throw BrowserHandoffCLIInputError.localExecutionRefused
                }
            }
        }

        private static func stopLocalDaemon(_ daemon: WinkDaemon?) async {
            guard let daemon, await daemon.requestStop() else { return }
            await daemon.waitUntilStopped()
        }

        static func makeToolContext(
            services: any WinkServiceProviding,
            snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)?,
            executionAuthority: MCPToolExecutionAuthority = .backgroundOnly,
            capturePreflightRefusal: MCPToolCapturePreflightRefusal? = nil
        ) -> MCPToolContext {
            let snapshotExecutionGate: MCPToolSnapshotExecutionGate
            if let agent = services.agent as? WinkAgentService {
                agent.configureSnapshotMutationCoordinator(snapshotMutationCoordinator)
                agent.configureCapturePreflightRefusal(capturePreflightRefusal)
                snapshotExecutionGate = agent.snapshotExecutionGate
            } else {
                snapshotExecutionGate = MCPToolSnapshotExecutionGate()
            }

            return MCPToolContext(
                services: services,
                snapshotMutationCoordinator: snapshotMutationCoordinator,
                snapshotExecutionGate: snapshotExecutionGate,
                executionAuthority: executionAuthority,
                capturePreflightRefusal: capturePreflightRefusal
            )
        }

        static func transportType(named name: String) -> WinkCore.TransportType? {
            switch name.lowercased() {
            case "stdio": .stdio
            case "http": .http
            case "sse": .sse
            default: nil
            }
        }
    }
}

@MainActor
extension MCPCommand.Serve: ParsableCommand {}
extension MCPCommand.Serve: AsyncRuntimeCommand {}
extension MCPCommand.Serve: PreRuntimeValidatingCommand {}
extension MCPCommand.Serve: RuntimeOptionsConfigurable {}

extension MCPCommand.Serve: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        if let transportOption = values.singleOption("transport") {
            self.transport = transportOption
        }
        if let portOption = try values.decodeOption("port", as: Int.self) {
            self.port = portOption
        }
        self.allowForeground = values.flag("allowForeground")
        self.allowTemporaryClipboard = values.flag("allowTemporaryClipboard")
        self.browserHandoff = values.singleOption("browserHandoff")
    }
}
