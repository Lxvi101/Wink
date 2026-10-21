import Commander
import Foundation
import WinkCore
import WinkFoundation

// MARK: - Image Capture Models

/// Re-export WinkCore types
typealias SavedFile = WinkCore.SavedFile

/// Extend WinkCore types to conform to Commander argument parsing for CLI usage
extension WinkCore.CaptureMode: @retroactive ExpressibleFromArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

extension WinkCore.ImageFormat: @retroactive ExpressibleFromArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

extension WinkCore.CaptureFocus: @retroactive ExpressibleFromArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

// MARK: - Application & Window Models

// Re-export WinkCore types
typealias WindowInfo = WinkCore.WindowInfo
typealias WindowBounds = WinkCore.WindowBounds
typealias TargetApplicationInfo = WinkCore.TargetApplicationInfo
typealias WindowListData = WinkCore.WindowListData

// MARK: - Error Types

/// Re-export CaptureError from WinkFoundation
typealias CaptureError = WinkFoundation.CaptureError
