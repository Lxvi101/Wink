import Foundation
import os.log
import WinkAgentRuntime
import WinkAutomation
import WinkAutomationKit
import WinkBridge
import WinkFoundation
import WinkVisualizer

/// Main-actor service container shared by the CLI, app, and agent runtime.
///
/// The default initializer constructs production services; the injected initializer accepts host or test services.
/// Call `installAgentRuntimeDefaults()` before using the default MCP context or tool registry, and keep this
/// container alive while those factories are in use. Installation is explicit and does not retain the container.
/// Native services manage their own bounded workers where blocking work must leave the main actor.
@MainActor
public final class WinkServices {
    /// Internal logger for debugging service initialization and coordination
    let logger = SystemLogger(subsystem: "boo.wink.core", category: "Services")

    /// Centralized logging service for consistent logging across all Wink components
    public let logging: any LoggingServiceProtocol

    /// Unified screenshot, target resolution, and optional element-detection pipeline
    public let desktopObservation: any DesktopObservationServiceProtocol

    /// Screen and window capture service supporting ScreenCaptureKit and legacy APIs
    public let screenCapture: any ScreenCaptureServiceProtocol

    /// Application discovery and enumeration service for finding running apps and windows
    public let applications: any ApplicationServiceProtocol

    /// Core UI automation service for mouse, keyboard, and accessibility interactions
    public let automation: any WinkAutomation.UIAutomationServiceProtocol

    /// Window management service for positioning, resizing, and organizing windows
    public let windows: any WindowManagementServiceProtocol

    /// Menu bar interaction service for navigating application menus
    public let menu: any MenuServiceProtocol

    /// macOS Dock interaction service for launching and managing Dock items
    public let dock: any DockServiceProtocol

    /// System dialog interaction service for handling alerts, file dialogs, etc.
    public let dialogs: any DialogServiceProtocol

    /// Snapshot and state management for automation workflows and history
    public let snapshots: any SnapshotManagerProtocol

    /// File system operations service for reading, writing, and manipulating files
    public let files: any FileServiceProtocol

    /// Clipboard service for reading/writing pasteboard contents
    public let clipboard: any ClipboardServiceProtocol

    /// Configuration management for user preferences and API keys
    public let configuration: ConfigurationManager

    /// Permissions verification service for checking macOS privacy permissions
    public let permissions: PermissionsService

    /// Audio input service for recording and transcription
    public let audioInput: AudioInputService

    /// Browser MCP client for Chrome DevTools automation
    public let browser: any BrowserMCPClientProviding

    /// Operations whose concrete native service owns the desktop lane at its dispatch leaf.
    private let nativeDesktopOperationLaneOperations: Set<WinkBridgeOperation>

    // Model provider is now handled internally by Tachikoma

    /// Intelligent automation agent service for natural language task execution
    public internal(set) var agent: (any AgentServiceProtocol)?

    /// Screen management service for multi-monitor support
    public let screens: any ScreenServiceProtocol

    /// Lock for thread-safe agent updates
    let agentLock = NSLock()

    /// Initialize with default service implementations.
    /// - Parameter initializeAgentService: When false, leaves `agent` unset until `refreshAgentService()` is called.
    @MainActor
    public init(
        inputPolicy: UIInputPolicy? = nil,
        initializeAgentService: Bool = true)
    {
        self.logger.debug("🚀 Initializing WinkServices with default implementations")

        let logging = LoggingService()
        self.logger.debug("\(AgentDisplayTokens.Status.success) LoggingService initialized")

        let apps = ApplicationService()
        self.logger.debug("\(AgentDisplayTokens.Status.success) ApplicationService initialized")

        let snapshots = SnapshotManager()
        self.logger.debug("\(AgentDisplayTokens.Status.success) SnapshotManager initialized")

        // Route automation feedback to the visualizer by default so users see
        // click/type/scroll/capture animations whenever Wink.app is around.
        let feedback = VisualizerAutomationFeedbackClient()

        let screenCap = ScreenCaptureService(loggingService: logging, feedbackClient: feedback)
        self.logger.debug("\(AgentDisplayTokens.Status.success) ScreenCaptureService initialized")

        let configuration = ConfigurationManager.shared
        self.logger.debug("\(AgentDisplayTokens.Status.success) ConfigurationManager initialized")

        let auto = UIAutomationService(
            snapshotManager: snapshots,
            loggingService: logging,
            searchPolicy: .balanced,
            inputPolicy: inputPolicy ?? configuration.getUIInputPolicy(),
            feedbackClient: feedback)
        self.logger.debug("\(AgentDisplayTokens.Status.success) UIAutomationService initialized")

        let windows = WindowManagementService(applicationService: apps, feedbackClient: feedback)
        self.logger.debug("\(AgentDisplayTokens.Status.success) WindowManagementService initialized")

        let menuSvc = MenuService(applicationService: apps, feedbackClient: feedback)
        self.logger.debug("\(AgentDisplayTokens.Status.success) MenuService initialized")

        let dockSvc = DockService(feedbackClient: feedback)
        self.logger.debug("\(AgentDisplayTokens.Status.success) DockService initialized")

        let screenSvc = ScreenService()
        self.logger.debug("\(AgentDisplayTokens.Status.success) ScreenService initialized")

        self.logging = logging
        self.desktopObservation = DesktopObservationService(
            screenCapture: screenCap,
            automation: auto,
            applications: apps,
            menu: menuSvc,
            screens: screenSvc,
            snapshotManager: snapshots)
        self.screenCapture = screenCap
        self.applications = apps
        self.automation = auto
        self.windows = windows
        self.menu = menuSvc
        self.dock = dockSvc
        self.screens = screenSvc

        self.dialogs = DialogService(feedbackClient: feedback)
        self.logger.debug("\(AgentDisplayTokens.Status.success) DialogService initialized")

        self.snapshots = snapshots

        self.files = FileService()
        self.logger.debug("\(AgentDisplayTokens.Status.success) FileService initialized")

        let clipboard = ClipboardService()
        self.clipboard = clipboard
        self.logger.debug("\(AgentDisplayTokens.Status.success) ClipboardService initialized")

        self.configuration = configuration

        self.permissions = PermissionsService()
        self.logger.debug("\(AgentDisplayTokens.Status.success) PermissionsService initialized")

        // Initialize AI service for audio/transcription features
        let aiService = WinkAIService()
        self.audioInput = AudioInputService(aiService: aiService)
        self.logger.debug("\(AgentDisplayTokens.Status.success) AudioInputService initialized")

        // Model provider is now handled internally by Tachikoma

        self.browser = BrowserMCPService()
        self.logger.debug("\(AgentDisplayTokens.Status.success) BrowserMCPService initialized")

        // Agent service will be initialized by createShared method
        self.agent = nil
        self.nativeDesktopOperationLaneOperations = WinkBridgeOperation.nativeDesktopOperationLaneOperations

        self.logger.debug("✨ WinkServices initialization complete")
        if initializeAgentService {
            self.refreshAgentService()
        }
    }

    /// Initialize with default services but a custom snapshot manager (e.g. in-memory for long-lived host apps).
    /// - Parameter initializeAgentService: When false, leaves `agent` unset until `refreshAgentService()` is called.
    @MainActor
    public convenience init(
        snapshotManager: any SnapshotManagerProtocol,
        inputPolicy: UIInputPolicy? = nil,
        initializeAgentService: Bool = true)
    {
        let logger = SystemLogger(subsystem: "boo.wink.core", category: "Services")
        logger.debug("🚀 Initializing WinkServices with default implementations (custom snapshots)")

        let logging = LoggingService()
        logger.debug("\(AgentDisplayTokens.Status.success) LoggingService initialized")

        let apps = ApplicationService()
        logger.debug("\(AgentDisplayTokens.Status.success) ApplicationService initialized")

        let snapshots = snapshotManager
        logger.debug("\(AgentDisplayTokens.Status.success) SnapshotManager initialized (custom)")

        // Route automation feedback to the visualizer by default so users see
        // click/type/scroll/capture animations whenever Wink.app is around.
        let feedback = VisualizerAutomationFeedbackClient()

        let screenCap = ScreenCaptureService(loggingService: logging, feedbackClient: feedback)
        logger.debug("\(AgentDisplayTokens.Status.success) ScreenCaptureService initialized")

        let configuration = ConfigurationManager.shared
        logger.debug("\(AgentDisplayTokens.Status.success) ConfigurationManager initialized")

        let auto = UIAutomationService(
            snapshotManager: snapshots,
            loggingService: logging,
            searchPolicy: .balanced,
            inputPolicy: inputPolicy ?? configuration.getUIInputPolicy(),
            feedbackClient: feedback)
        logger.debug("\(AgentDisplayTokens.Status.success) UIAutomationService initialized")

        let windows = WindowManagementService(applicationService: apps, feedbackClient: feedback)
        logger.debug("\(AgentDisplayTokens.Status.success) WindowManagementService initialized")

        let menuSvc = MenuService(applicationService: apps, feedbackClient: feedback)
        logger.debug("\(AgentDisplayTokens.Status.success) MenuService initialized")

        let dockSvc = DockService(feedbackClient: feedback)
        logger.debug("\(AgentDisplayTokens.Status.success) DockService initialized")

        let dialogs = DialogService(feedbackClient: feedback)
        logger.debug("\(AgentDisplayTokens.Status.success) DialogService initialized")

        let files = FileService()
        logger.debug("\(AgentDisplayTokens.Status.success) FileService initialized")

        let clipboard = ClipboardService()
        logger.debug("\(AgentDisplayTokens.Status.success) ClipboardService initialized")

        let permissions = PermissionsService()
        logger.debug("\(AgentDisplayTokens.Status.success) PermissionsService initialized")

        let audioInput = AudioInputService(aiService: WinkAIService())
        logger.debug("\(AgentDisplayTokens.Status.success) AudioInputService initialized")

        let screens = ScreenService()
        logger.debug("\(AgentDisplayTokens.Status.success) ScreenService initialized")

        self.init(
            logging: logging,
            screenCapture: screenCap,
            applications: apps,
            automation: auto,
            windows: windows,
            menu: menuSvc,
            dock: dockSvc,
            dialogs: dialogs,
            snapshots: snapshots,
            files: files,
            clipboard: clipboard,
            permissions: permissions,
            audioInput: audioInput,
            browser: BrowserMCPService(),
            configuration: configuration,
            agent: nil,
            screens: screens,
            nativeDesktopOperationLaneOperations: WinkBridgeOperation.nativeDesktopOperationLaneOperations)

        logger.debug("✨ WinkServices initialization complete (custom snapshots)")
        if initializeAgentService {
            self.refreshAgentService()
        }
    }

    /// Initialize with custom service implementations (for testing)
    @MainActor
    public init(
        logging: (any LoggingServiceProtocol)? = nil,
        screenCapture: any ScreenCaptureServiceProtocol,
        applications: any ApplicationServiceProtocol,
        automation: any WinkAutomation.UIAutomationServiceProtocol,
        windows: any WindowManagementServiceProtocol,
        menu: any MenuServiceProtocol,
        dock: any DockServiceProtocol,
        dialogs: any DialogServiceProtocol,
        snapshots: any SnapshotManagerProtocol,
        files: any FileServiceProtocol,
        clipboard: any ClipboardServiceProtocol,
        permissions: PermissionsService? = nil,
        audioInput: AudioInputService? = nil,
        browser: (any BrowserMCPClientProviding)? = nil,
        agent: (any AgentServiceProtocol)? = nil,
        configuration: ConfigurationManager? = nil,
        screens: (any ScreenServiceProtocol)? = nil,
        nativeDesktopOperationLaneOperations: Set<WinkBridgeOperation> = [])
    {
        self.logger.debug("🚀 Initializing WinkServices with custom implementations")
        self.logging = logging ?? LoggingService()
        self.screenCapture = screenCapture
        self.applications = applications
        self.automation = automation
        let screenSvc = screens ?? ScreenService()
        self.desktopObservation = DesktopObservationService(
            screenCapture: screenCapture,
            automation: automation,
            applications: applications,
            menu: menu,
            screens: screenSvc,
            snapshotManager: snapshots)
        self.windows = windows
        self.menu = menu
        self.dock = dock
        self.dialogs = dialogs
        self.snapshots = snapshots
        self.files = files
        self.clipboard = clipboard
        self.permissions = permissions ?? PermissionsService()
        self.audioInput = audioInput ?? AudioInputService(aiService: WinkAIService())
        self.browser = browser ?? BrowserMCPService()
        self.agent = agent
        self.configuration = configuration ?? ConfigurationManager.shared
        self.screens = screenSvc
        self.nativeDesktopOperationLaneOperations = nativeDesktopOperationLaneOperations.union([.desktopObservation])
        // Model provider is now handled internally by Tachikoma

        self.logger.debug("✨ WinkServices initialization complete (custom)")
    }

    /// Internal initializer that takes all services including agent
    private init(
        logging: any LoggingServiceProtocol,
        screenCapture: any ScreenCaptureServiceProtocol,
        applications: any ApplicationServiceProtocol,
        automation: any WinkAutomation.UIAutomationServiceProtocol,
        windows: any WindowManagementServiceProtocol,
        menu: any MenuServiceProtocol,
        dock: any DockServiceProtocol,
        dialogs: any DialogServiceProtocol,
        snapshots: any SnapshotManagerProtocol,
        files: any FileServiceProtocol,
        clipboard: any ClipboardServiceProtocol,
        permissions: PermissionsService,
        audioInput: AudioInputService,
        browser: any BrowserMCPClientProviding,
        configuration: ConfigurationManager,
        agent: (any AgentServiceProtocol)?,
        screens: any ScreenServiceProtocol,
        nativeDesktopOperationLaneOperations: Set<WinkBridgeOperation>)
    {
        self.logging = logging
        self.screenCapture = screenCapture
        self.applications = applications
        self.automation = automation
        self.desktopObservation = DesktopObservationService(
            screenCapture: screenCapture,
            automation: automation,
            applications: applications,
            menu: menu,
            screens: screens,
            snapshotManager: snapshots)
        self.windows = windows
        self.menu = menu
        self.dock = dock
        self.dialogs = dialogs
        self.snapshots = snapshots
        self.files = files
        self.clipboard = clipboard
        self.permissions = permissions
        self.audioInput = audioInput
        self.browser = browser
        self.configuration = configuration
        self.agent = agent
        self.screens = screens
        self.nativeDesktopOperationLaneOperations = nativeDesktopOperationLaneOperations
        // Model provider is now handled internally by Tachikoma
    }
}

extension WinkServices: WinkServiceProviding {}
extension WinkServices: WinkBridgeServiceProviding {
    public var supportsClassicCaptureWithoutScreenCaptureKit: Bool {
        self.screenCapture is ScreenCaptureService
    }

    public var supportsScreenCaptureKitProcessOwnership: Bool {
        self.screenCapture is ScreenCaptureService
    }

    public func ownsDesktopOperationLane(for operation: WinkBridgeOperation) -> Bool {
        self.nativeDesktopOperationLaneOperations.contains(operation)
    }
}

typealias SystemLogger = os.Logger
