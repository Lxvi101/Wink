import WinkAutomation
import WinkCore

@MainActor
enum RuntimeServiceFactory {
    static func makeLocalServices(options: CommandRuntimeOptions) -> WinkServices {
        WinkServices(
            snapshotManager: SnapshotManager(
                desktopMutationWatermarkStore: DesktopMutationWatermarkStore()
            ),
            inputPolicy: WinkAutomation.ConfigurationManager.shared.getUIInputPolicy(
                cliStrategy: options.inputStrategy
            ),
            initializeAgentService: options.requiresAgentService
        )
    }
}
