import WinkAgentRuntime
import WinkAutomation
import WinkCore
import WinkFoundationTestSupport
import Tachikoma

@MainActor
public enum AuthorityTestSupport {
    public static func services(snapshotManager: (any SnapshotManagerProtocol)? = nil) -> WinkServices {
        WinkServices(
            snapshotManager: snapshotManager ?? InMemorySnapshotManager(),
            initializeAgentService: false)
    }

    public static func agent(
        services: any WinkServiceProviding,
        defaultModel: LanguageModel = .anthropic(.opus5),
        snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)? = nil,
        snapshotExecutionGate: MCPToolSnapshotExecutionGate = MCPToolSnapshotExecutionGate(),
        sessionManager: AgentSessionManager? = nil) throws -> WinkAgentService
    {
        try WinkAgentService(
            services: services,
            defaultModel: defaultModel,
            snapshotMutationCoordinator: snapshotMutationCoordinator,
            snapshotExecutionGate: snapshotExecutionGate,
            sessionManager: sessionManager ??
                AgentSessionManager(sessionDirectory: AgentTestStorage.sessionDirectory()))
    }
}
