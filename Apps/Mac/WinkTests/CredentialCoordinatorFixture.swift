import Foundation
import WinkAutomation
@testable import Wink

/// Only the coordinator/file graph is locally safe. This does not isolate a full WinkSettings instance.
@MainActor
final class CredentialCoordinatorFixture {
    let directory: URL
    let file: CredentialFile
    var preferences: [WinkCredential: String] = [:]
    var runtimeRefreshes = 0

    init(directory: URL? = nil) {
        let root = ProcessInfo.processInfo.environment["WINK_CREDENTIAL_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? root.appendingPathComponent(UUID().uuidString)
        self.file = CredentialFile(url: self.directory.appendingPathComponent("credentials"))
    }

    func coordinator() -> ProviderCredentialCoordinator {
        ProviderCredentialCoordinator(
            file: self.file,
            legacy: LegacyCredentialPreferences(
                read: { self.preferences[$0] },
                remove: { self.preferences.removeValue(forKey: $0) }),
            runtimeDidChange: { self.runtimeRefreshes += 1 })
    }

    deinit {
        try? FileManager.default.removeItem(at: self.directory)
    }
}
