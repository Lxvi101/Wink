import Foundation
import WinkCore

// MARK: - Time Formatting Helpers

/// Re-export the formatDuration function from WinkCore for backward compatibility
public func formatDuration(_ seconds: TimeInterval) -> String {
    WinkCore.formatDuration(seconds)
}

/// Format a date as a human-readable time ago string
public func formatTimeAgo(_ date: Date, from now: Date = Date()) -> String {
    WinkCore.formatTimeAgo(date, from: now)
}
