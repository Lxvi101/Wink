import Foundation

enum WinkSettingsTab: Hashable, CaseIterable {
    case general
    case agent
    case providers
    case visualizer
    case permissions
    case about

    var title: String {
        switch self {
        case .general: "General"
        case .agent: "Agent"
        case .providers: "Providers"
        case .visualizer: "Visualizer"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }
}

@MainActor
enum SettingsTabRouter {
    private static var pending: WinkSettingsTab?

    static func request(_ tab: WinkSettingsTab) {
        self.pending = tab
    }

    static func consumePending() -> WinkSettingsTab? {
        defer { self.pending = nil }
        return self.pending
    }
}

extension Notification.Name {
    static let winkSelectSettingsTab = Notification.Name("winkSelectSettingsTab")
}
