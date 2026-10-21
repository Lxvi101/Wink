import Testing
@testable import WinkAgentRuntime
@testable import WinkAutomation
@testable import WinkCore
@testable import WinkVisualizer

@Test
func `configuration manager`() {
    let manager = ConfigurationManager.shared
    let providers = manager.getAIProviders()
    #expect(!providers.isEmpty)
}
