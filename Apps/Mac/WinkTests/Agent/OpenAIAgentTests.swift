import Foundation
import WinkCore
import Testing
@testable import Wink

@Suite(.tags(.ai, .unit), .disabled("Uses full WinkServices which may hang"))
@MainActor
struct WinkAgentServiceTests {
    var agentService: WinkAgentService!
    var settings: WinkSettings!
    var sessionStore: SessionStore!
    var agent: WinkAgent!

    mutating func setup() {
        let services = WinkServices()
        do {
            self.agentService = try WinkAgentService(services: services)
        } catch {
            Issue.record("Failed to initialize WinkAgentService: \\(error)")
            self.agentService = nil
        }
        self.settings = makeTestSettings()
        self.settings.connectServices(services)
        self.sessionStore = SessionStore()
        self.agent = WinkAgent(
            settings: self.settings,
            sessionStore: self.sessionStore,
            services: services)
    }

    @Test
    mutating func `Agent service initializes correctly`() {
        self.setup()
        #expect(self.agentService != nil)
    }

    @Test
    mutating func `Agent creates a valid set of tools`() {
        self.setup()
        let tools = self.agentService.createAgentTools()
        #expect(!tools.isEmpty)

        // Check for a few expected tools
        #expect(tools.contains { $0.name == "see" })
        #expect(tools.contains { $0.name == "click" })
        #expect(tools.contains { $0.name == "type" })
    }

    @Test
    mutating func `Task execution requires a valid API key`() async {
        self.setup()
        self.settings.openAIAPIKey = ""

        await #expect(throws: AgentError.serviceUnavailable) {
            try await agent.executeTask("What time is it?")
        }
    }

    @Test
    mutating func `Dry run mode returns successfully without execution`() async throws {
        self.setup()
        self.settings.openAIAPIKey = "sk-test-key" // Needs a dummy key

        _ = try await self.agent.executeTask("Test task")

        // Dry run should create a session and a user message, but not execute
        let sessions = self.sessionStore.sessions
        #expect(sessions.count == 1)
        #expect(sessions.first?.messages.count == 1)
        #expect(sessions.first?.messages.first?.role == .user)
    }
}
