import Foundation
import WinkCore
import WinkFoundation

@MainActor
enum SnapshotValidation {
    static func requireDetectionResult(
        snapshotId: String,
        snapshots: any SnapshotManagerProtocol
    ) async throws -> ElementDetectionResult {
        guard let result = try await snapshots.getDetectionResult(snapshotId: snapshotId) else {
            throw WinkError.snapshotNotFound(
                """
                Snapshot '\(snapshotId)' was not found (or has no UI map). \
                Run 'wink see' again, omit --snapshot, or pass --snapshot latest.
                """
            )
        }
        return result
    }
}
