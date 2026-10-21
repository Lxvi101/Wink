import Foundation
@testable import Wink

@MainActor
func makeTestSettings() -> WinkSettings {
    let fixture = CredentialCoordinatorFixture()
    return WinkSettings(credentialCoordinator: fixture.coordinator())
}
