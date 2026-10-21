import Foundation
import WinkFoundation

@MainActor
final class LegacyScreenCaptureOperator: LegacyScreenCaptureOperating, @unchecked Sendable {
    let logger: CategoryLogger

    init(logger: CategoryLogger) {
        self.logger = logger
    }
}
