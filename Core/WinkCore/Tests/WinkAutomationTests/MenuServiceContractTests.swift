import WinkAutomation
import WinkFoundation
import Testing

@MainActor
struct MenuServiceContractTests {
    @Test
    func `listMenus throws appNotFound for missing app`() async throws {
        let service = MenuService()

        do {
            _ = try await service.listMenus(for: "DefinitelyNotRunningApp-ContractTest")
            Issue.record("Expected appNotFound error")
        } catch let error as WinkError {
            switch error {
            case .appNotFound:
                // success
                break
            default:
                Issue.record("Unexpected WinkError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
