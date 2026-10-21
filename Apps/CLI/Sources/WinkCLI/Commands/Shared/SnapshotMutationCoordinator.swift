import Foundation
import WinkCore
import WinkFoundation

@MainActor
enum SnapshotMutationCoordinator {
    static func perform<Value>(
        snapshotId: String?,
        snapshots: any SnapshotManagerProtocol,
        targetIdentity: DesktopTargetIdentity? = nil,
        operation: () async throws -> Value,
        outcome: (Value) -> DesktopActionOutcome?
    ) async throws -> Value {
        try await snapshots.withSnapshotMutation(
            snapshotId: snapshotId,
            targetIdentity: targetIdentity,
            operation: operation,
            outcome: outcome
        )
    }
}
