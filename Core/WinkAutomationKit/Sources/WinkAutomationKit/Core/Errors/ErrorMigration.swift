import Foundation
import WinkFoundation

// MARK: - Error Migration Support

/// Temporary struct to support gradual migration from struct-based errors to WinkError
public struct NotFoundError {
    public let code: StandardErrorCode
    public let userMessage: String
    public let context: [String: String]

    public init(code: StandardErrorCode, userMessage: String, context: [String: String]) {
        self.code = code
        self.userMessage = userMessage
        self.context = context
    }

    /// Factory methods that return WinkError
    public static func application(_ identifier: String) -> WinkError {
        .appNotFound(identifier)
    }

    public static func window(app: String, index: Int? = nil) -> WinkError {
        .windowNotFound()
    }

    public static func element(_ description: String) -> WinkError {
        .elementNotFound(description)
    }

    public static func snapshot(_ id: String) -> WinkError {
        .snapshotNotFound(id)
    }
}

/// Make NotFoundError throwable by converting to WinkError
extension NotFoundError: Error {
    public var asWinkError: WinkError {
        switch self.code {
        case .applicationNotFound:
            if let app = context["identifier"] ?? context["app"] {
                return .appNotFound(app)
            }
            return .operationError(message: self.userMessage)
        case .windowNotFound:
            return .windowNotFound(criteria: nil)
        case .elementNotFound:
            if let element = context["element"] {
                return .elementNotFound(element)
            }
            return .operationError(message: self.userMessage)
        case .snapshotNotFound:
            if let id = context["snapshot_id"] {
                return .snapshotNotFound(id)
            }
            return .operationError(message: self.userMessage)
        case .sessionNotFound:
            if let id = context["session_id"] {
                return .sessionNotFound(id)
            }
            return .operationError(message: self.userMessage)
        case .menuNotFound:
            if let app = context["application"] {
                return .menuNotFound(app)
            }
            return .operationError(message: self.userMessage)
        default:
            return .operationError(message: self.userMessage)
        }
    }
}

/// Temporary struct for PermissionError migration
public enum PermissionError {
    public static func screenRecording() -> WinkError {
        .permissionDeniedScreenRecording
    }

    public static func accessibility() -> WinkError {
        .permissionDeniedAccessibility
    }
}
