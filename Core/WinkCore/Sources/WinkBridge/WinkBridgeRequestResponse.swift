import CoreGraphics
import Foundation
import WinkAutomationKit

public enum WinkBridgeRequest: Codable, Sendable {
    indirect case attestedOperation(WinkBridgeAttestedOperationRequest)
    indirect case projectedAction(WinkBridgeProjectedActionRequest)
    case handshake(WinkBridgeHandshake)
    case permissionsStatus
    case requestPostEventPermission
    case daemonStatus
    case daemonStop
    case daemonStopIf(WinkBridgeDaemonStopRequest)
    case agentExecutionTrace(WinkBridgeAgentExecutionTraceRequest)
    case observeProcessGeneration(WinkBridgeProcessGenerationObservationRequest)
    case certificationProducerAttestation(WinkBridgeCertificationProducerAttestationRequest)
    case browserStatus(WinkBridgeBrowserChannelRequest)
    case browserConnect(WinkBridgeBrowserChannelRequest)
    case browserDisconnect
    case browserExecute(WinkBridgeBrowserExecuteRequest)
    case browserSessionBootstrap(WinkBridgeBrowserSessionBootstrapRequest)
    case browserSessionControl(WinkBridgeBrowserSessionControlRequest)
    case captureScreen(WinkBridgeCaptureScreenRequest)
    case captureWindow(WinkBridgeCaptureWindowRequest)
    case captureFrontmost(WinkBridgeCaptureFrontmostRequest)
    case captureArea(WinkBridgeCaptureAreaRequest)
    case detectElements(WinkBridgeDetectElementsRequest)
    case inspectAccessibilityTree(WinkBridgeInspectAccessibilityTreeRequest)
    case getFocusedElement(WinkBridgeFocusedElementRequest)
    case desktopObservation(DesktopObservationRequest)
    case click(WinkBridgeClickRequest)
    case type(WinkBridgeTypeRequest)
    case typeActions(WinkBridgeTypeActionsRequest)
    case targetedTypeActions(WinkBridgeTargetedTypeActionsRequest)
    case exactWindowTargetedTypeActions(WinkBridgeExactWindowTypeActionsRequest)
    case exactWindowPixelFocusType(WinkBridgeExactWindowPixelFocusTypeRequest)
    case foregroundModifierClick(WinkBridgeForegroundModifierClickRequest)
    case setValue(WinkBridgeSetValueRequest)
    case selectText(WinkBridgeSelectTextRequest)
    case performAction(WinkBridgePerformActionRequest)
    case scroll(WinkBridgeScrollRequest)
    case targetedScroll(WinkBridgeScrollRequest)
    case hotkey(WinkBridgeHotkeyRequest)
    case targetedHotkey(WinkBridgeTargetedHotkeyRequest)
    case exactWindowTargetedHotkey(WinkBridgeExactWindowHotkeyRequest)
    case createExactWindowHeldPointerOwner
    case beginExactWindowHeldPointer(WinkBridgeBeginHeldPointerRequest)
    case exactWindowDrag(ExactWindowDragRequest)
    case releaseExactWindowHeldPointer(WinkBridgeFinishHeldPointerRequest)
    case revokeExactWindowHeldPointer(WinkBridgeFinishHeldPointerRequest)
    case disconnectExactWindowHeldPointerOwner(WinkBridgeHeldPointerOwnerRequest)
    case targetedClick(WinkBridgeTargetedClickRequest)
    case swipe(WinkBridgeSwipeRequest)
    case drag(WinkBridgeDragRequest)
    case moveMouse(WinkBridgeMoveMouseRequest)
    case waitForElement(WinkBridgeWaitRequest)
    case listWindows(WinkBridgeWindowTargetRequest)
    case listWindowMutationInventory(WinkBridgeWindowTargetRequest)
    case focusWindow(WinkBridgeWindowTargetRequest)
    case moveWindow(WinkBridgeWindowMoveRequest)
    case resizeWindow(WinkBridgeWindowResizeRequest)
    case setWindowBounds(WinkBridgeWindowBoundsRequest)
    case closeWindow(WinkBridgeWindowTargetRequest)
    case backgroundCloseWindow(WinkBridgeWindowTargetRequest)
    case minimizeWindow(WinkBridgeWindowTargetRequest)
    case restoreWindow(WinkBridgeWindowTargetRequest)
    case maximizeWindow(WinkBridgeWindowTargetRequest)
    case getFocusedWindow
    case listApplications
    case listApplicationMutationInventory
    case findApplication(WinkBridgeAppIdentifierRequest)
    case getFrontmostApplication
    case isApplicationRunning(WinkBridgeAppIdentifierRequest)
    case launchApplication(WinkBridgeAppIdentifierRequest)
    case launchApplicationWithOptions(ApplicationLaunchRequest)
    case relaunchApplicationWithOptions(ApplicationRelaunchRequest)
    case activateApplication(WinkBridgeAppIdentifierRequest)
    case quitApplication(WinkBridgeQuitAppRequest)
    case hideApplication(WinkBridgeAppIdentifierRequest)
    case unhideApplication(WinkBridgeAppIdentifierRequest)
    case hideOtherApplications(WinkBridgeAppIdentifierRequest)
    case showAllApplications
    case listMenus(WinkBridgeMenuListRequest)
    case listFrontmostMenus
    case clickMenuItem(WinkBridgeMenuClickRequest)
    case clickMenuItemByName(WinkBridgeMenuClickByNameRequest)
    case listMenuExtras
    case clickMenuExtra(WinkBridgeMenuBarClickByNameRequest)
    case menuExtraOpenMenuFrame(WinkBridgeMenuExtraOpenRequest)
    case listMenuBarItems(Bool)
    case prepareMenuBarItem(MenuBarItemPreparationRequest)
    case clickMenuBarItemNamed(WinkBridgeMenuBarClickByNameRequest)
    case clickMenuBarItemIndex(WinkBridgeMenuBarClickByIndexRequest)
    case listDockItems(WinkBridgeDockListRequest)
    case launchDockItem(WinkBridgeDockLaunchRequest)
    case rightClickDockItem(WinkBridgeDockRightClickRequest)
    case hideDock
    case showDock
    case isDockHidden
    case findDockItem(WinkBridgeDockFindRequest)
    case dialogFindActive(WinkBridgeDialogFindRequest)
    case dialogClickButton(WinkBridgeDialogClickButtonRequest)
    case backgroundDialogClickButton(WinkBridgeDialogClickButtonRequest)
    case dialogEnterText(WinkBridgeDialogEnterTextRequest)
    case dialogHandleFile(WinkBridgeDialogHandleFileRequest)
    case dialogDismiss(WinkBridgeDialogDismissRequest)
    case dialogListElements(WinkBridgeDialogFindRequest)
    case targetedDialogListElements(DialogTargetSelector)
    case prepareDialogAction(DialogActionPreparationRequest)
    case exactDialogClickButton(PreparedDialogActionReceipt)
    case exactDialogDismiss(PreparedDialogActionReceipt)
    case exactDialogEnterText(DialogInputExecutionRequest)
    case exactDialogForceDismiss(DialogForcedDismissExecutionRequest)
    case createSnapshot(WinkBridgeCreateSnapshotRequest)
    case storeDetectionResult(WinkBridgeStoreDetectionRequest)
    case getDetectionResult(WinkBridgeGetDetectionRequest)
    case ownsSnapshot(WinkBridgeOwnsSnapshotRequest)
    case storeScreenshot(WinkBridgeStoreScreenshotRequest)
    case storeObservationSnapshot(WinkBridgeStoreObservationSnapshotRequest)
    case storeAnnotatedScreenshot(WinkBridgeStoreAnnotatedScreenshotRequest)
    case listSnapshots
    case getMostRecentSnapshot(WinkBridgeGetMostRecentSnapshotRequest)
    case invalidateImplicitLatestSnapshot(WinkBridgeInvalidateImplicitLatestSnapshotRequest)
    case beginSnapshotMutation(WinkBridgeBeginSnapshotMutationRequest)
    case finishSnapshotMutation(WinkBridgeFinishSnapshotMutationRequest)
    case cleanSnapshot(WinkBridgeCleanSnapshotRequest)
    case cleanSnapshotsOlderThan(WinkBridgeCleanSnapshotsOlderRequest)
    case cleanAllSnapshots
    case appleScriptProbe
}

extension WinkBridgeRequest {
    public var operation: WinkBridgeOperation {
        switch self {
        case let .attestedOperation(payload): payload.request.operation
        case let .projectedAction(payload): payload.request.operation
        case .handshake: .permissionsStatus
        case .permissionsStatus: .permissionsStatus
        case .requestPostEventPermission: .requestPostEventPermission
        case .daemonStatus: .daemonStatus
        case .daemonStop: .daemonStop
        case .daemonStopIf: .daemonStop
        case .agentExecutionTrace: .agentExecutionTrace
        case .observeProcessGeneration: .observeProcessGeneration
        case .certificationProducerAttestation: .certificationProducerAttestation
        case .browserStatus: .browserStatus
        case .browserConnect: .browserConnect
        case .browserDisconnect: .browserDisconnect
        case .browserExecute: .browserExecute
        case .browserSessionBootstrap: .browserSessionBootstrap
        case .browserSessionControl: .browserSessionControl
        case .captureScreen: .captureScreen
        case .captureWindow: .captureWindow
        case .captureFrontmost: .captureFrontmost
        case .captureArea: .captureArea
        case .detectElements: .detectElements
        case .inspectAccessibilityTree: .inspectAccessibilityTree
        case .getFocusedElement: .getFocusedElement
        case .desktopObservation: .desktopObservation
        case .click: .click
        case .type: .type
        case .typeActions: .typeActions
        case .targetedTypeActions: .targetedTypeActions
        case .exactWindowTargetedTypeActions: .exactWindowTargetedTypeActions
        case .exactWindowPixelFocusType: .exactWindowPixelFocusType
        case .foregroundModifierClick: .foregroundModifierClick
        case .setValue: .setValue
        case .selectText: .selectText
        case .performAction: .performAction
        case .scroll: .scroll
        case .targetedScroll: .targetedScroll
        case .hotkey: .hotkey
        case .targetedHotkey: .targetedHotkey
        case .exactWindowTargetedHotkey: .exactWindowTargetedHotkey
        case .createExactWindowHeldPointerOwner: .createExactWindowHeldPointerOwner
        case .beginExactWindowHeldPointer: .beginExactWindowHeldPointer
        case .exactWindowDrag: .exactWindowDrag
        case .releaseExactWindowHeldPointer: .releaseExactWindowHeldPointer
        case .revokeExactWindowHeldPointer: .revokeExactWindowHeldPointer
        case .disconnectExactWindowHeldPointerOwner: .disconnectExactWindowHeldPointerOwner
        case let .targetedClick(payload):
            payload.targetWindowID == nil ? .targetedClick : .exactWindowTargetedClick
        case .swipe: .swipe
        case .drag: .drag
        case .moveMouse: .moveMouse
        case .waitForElement: .waitForElement
        case .listWindows, .listWindowMutationInventory: .listWindows
        case .focusWindow: .focusWindow
        case .moveWindow: .moveWindow
        case .resizeWindow: .resizeWindow
        case .setWindowBounds: .setWindowBounds
        case .closeWindow: .closeWindow
        case .backgroundCloseWindow: .backgroundCloseWindow
        case .minimizeWindow: .minimizeWindow
        case .restoreWindow: .restoreWindow
        case .maximizeWindow: .maximizeWindow
        case .getFocusedWindow: .getFocusedWindow
        case .listApplications, .listApplicationMutationInventory: .listApplications
        case .findApplication: .findApplication
        case .getFrontmostApplication: .getFrontmostApplication
        case .isApplicationRunning: .isApplicationRunning
        case .launchApplication: .launchApplication
        case .launchApplicationWithOptions: .launchApplicationWithOptions
        case .relaunchApplicationWithOptions: .relaunchApplicationWithOptions
        case .activateApplication: .activateApplication
        case .quitApplication: .quitApplication
        case .hideApplication: .hideApplication
        case .unhideApplication: .unhideApplication
        case .hideOtherApplications: .hideOtherApplications
        case .showAllApplications: .showAllApplications
        case .listMenus: .listMenus
        case .listFrontmostMenus: .listFrontmostMenus
        case .clickMenuItem: .clickMenuItem
        case .clickMenuItemByName: .clickMenuItemByName
        case .listMenuExtras: .listMenuExtras
        case .clickMenuExtra: .clickMenuExtra
        case .menuExtraOpenMenuFrame: .menuExtraOpenMenuFrame
        case .listMenuBarItems: .listMenuBarItems
        case .prepareMenuBarItem: .prepareMenuBarItem
        case .clickMenuBarItemNamed: .clickMenuBarItemNamed
        case .clickMenuBarItemIndex: .clickMenuBarItemIndex
        case .listDockItems: .listDockItems
        case .launchDockItem: .launchDockItem
        case .rightClickDockItem: .rightClickDockItem
        case .hideDock: .hideDock
        case .showDock: .showDock
        case .isDockHidden: .isDockHidden
        case .findDockItem: .findDockItem
        case .dialogFindActive: .dialogFindActive
        case .dialogClickButton: .dialogClickButton
        case .backgroundDialogClickButton: .backgroundDialogClickButton
        case .dialogEnterText: .dialogEnterText
        case .dialogHandleFile: .dialogHandleFile
        case .dialogDismiss: .dialogDismiss
        case .dialogListElements: .dialogListElements
        case .targetedDialogListElements: .targetedDialogListElements
        case .prepareDialogAction: .prepareDialogAction
        case .exactDialogClickButton: .exactDialogClickButton
        case .exactDialogDismiss: .exactDialogDismiss
        case .exactDialogEnterText: .exactDialogEnterText
        case .exactDialogForceDismiss: .exactDialogForceDismiss
        case .createSnapshot: .createSnapshot
        case .storeDetectionResult: .storeDetectionResult
        case .getDetectionResult: .getDetectionResult
        case .ownsSnapshot: .ownsSnapshot
        case .storeScreenshot: .storeScreenshot
        case .storeObservationSnapshot: .storeObservationSnapshot
        case .storeAnnotatedScreenshot: .storeAnnotatedScreenshot
        case .listSnapshots: .listSnapshots
        case .getMostRecentSnapshot: .getMostRecentSnapshot
        case .invalidateImplicitLatestSnapshot: .invalidateImplicitLatestSnapshot
        case .beginSnapshotMutation: .beginSnapshotMutation
        case .finishSnapshotMutation: .finishSnapshotMutation
        case .cleanSnapshot: .cleanSnapshot
        case .cleanSnapshotsOlderThan: .cleanSnapshotsOlderThan
        case .cleanAllSnapshots: .cleanAllSnapshots
        case .appleScriptProbe: ._appleScriptProbe
        }
    }
}

public enum WinkBridgeResponse: Codable, Sendable {
    indirect case attestedOperation(WinkBridgeAttestedOperationResponse)
    case operationSessionRollover(WinkBridgeOperationSessionRefusal)
    indirect case projectedAction(WinkBridgeProjectedActionResponse)
    case handshake(WinkBridgeHandshakeResponse)
    case permissionsStatus(PermissionsStatus)
    case daemonStatus(WinkDaemonStatus)
    case agentExecutionTrace(WinkBridgeAgentExecutionTraceResponse)
    case processGenerationObservation(WinkBridgeProcessGenerationObservationResponse)
    case certificationProducerAttestation(WinkBridgeCertificationProducerAttestationResponse)
    case browserStatus(WinkBridgeBrowserStatus)
    case browserToolResponse(WinkBridgeBrowserToolResponse)
    case browserSessionBootstrap(WinkBridgeBrowserSessionBootstrapResponse)
    case capture(CaptureResult)
    case elementDetection(ElementDetectionResult)
    case focusedElement(UIFocusInfo?)
    case desktopObservation(DesktopObservationResult)
    case ok
    case waitResult(WaitForElementResult)
    case windows([ServiceWindowInfo])
    case windowMutationInventory(DesktopTargetPlanning.Inventory<ServiceWindowInfo>)
    case window(ServiceWindowInfo?)
    case applications([ServiceApplicationInfo])
    case applicationMutationInventory(DesktopTargetPlanning.Inventory<ServiceApplicationInfo>)
    case application(ServiceApplicationInfo)
    case bool(Bool)
    case typeResult(TypeResult)
    case foregroundModifierClickResult(ForegroundModifierClickResult)
    case exactWindowHeldPointerOwner(ExactWindowHeldPointerOwner)
    case exactWindowHeldPointerReceipt(ExactWindowHeldPointerReceipt)
    case exactWindowHeldPointerTermination(ExactWindowHeldPointerTermination?)
    case elementActionResult(ElementActionResult)
    case clickResult(ClickResult)
    case menuStructure(MenuStructure)
    case menuExtras([MenuExtraInfo])
    case menuBarItems([MenuBarItemInfo])
    case dockItems([DockItem])
    case dockItem(DockItem?)
    case rect(CGRect?)
    case dialogInfo(DialogInfo)
    case dialogElements(DialogElements)
    case dialogResult(DialogActionResult)
    case preparedDialogAction(PreparedDialogActionReceipt)
    case snapshotId(String)
    case snapshotMutationLease(SnapshotMutationLease)
    case snapshots([SnapshotInfo])
    case detection(ElementDetectionResult)
    case int(Int)
    case error(WinkBridgeErrorEnvelope)
}

/// A concrete reference boundary for recursively wrapped Bridge requests.
///
/// The synthesized decoder for this large enum reserves a substantial stack frame. Decoding both
/// attested and projected wrappers through that witness at every nesting level can exhaust a Swift
/// cooperative thread's stack even though the wire value has only the permitted finite nesting.
final class WinkBridgeRequestCodingBox: Codable, @unchecked Sendable {
    let value: WinkBridgeRequest

    private struct RequestCaseKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    private enum AssociatedValueKey: String, CodingKey {
        case value = "_0"
    }

    init(_ value: WinkBridgeRequest) {
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RequestCaseKey.self)
        if container.allKeys.count == 1, let key = container.allKeys.first {
            let associated = try container.nestedContainer(
                keyedBy: AssociatedValueKey.self,
                forKey: key)
            switch key.stringValue {
            case "attestedOperation", "attested_operation":
                self.value = try .attestedOperation(associated.decode(
                    WinkBridgeAttestedOperationRequest.self,
                    forKey: .value))
                return
            case "projectedAction", "projected_action":
                self.value = try .projectedAction(associated.decode(
                    WinkBridgeProjectedActionRequest.self,
                    forKey: .value))
                return
            default:
                break
            }
        }
        self.value = try WinkBridgeRequest(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try self.value.encode(to: encoder)
    }
}

/// A concrete reference boundary for recursively wrapped Bridge responses.
///
/// Directly decoding the recursive enum from both wrapper payloads can ask the Swift runtime for
/// an indefinitely recursive generic metadata path during cold concurrent startup. The box keeps
/// the synthesized wire bytes unchanged while giving those recursive cases finite witnesses.
final class WinkBridgeResponseCodingBox: Codable, @unchecked Sendable {
    let value: WinkBridgeResponse

    private struct ResponseCaseKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    private enum AssociatedValueKey: String, CodingKey {
        case value = "_0"
    }

    init(_ value: WinkBridgeResponse) {
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: ResponseCaseKey.self)
        if container.allKeys.count == 1, let key = container.allKeys.first {
            let associated = try container.nestedContainer(
                keyedBy: AssociatedValueKey.self,
                forKey: key)
            switch key.stringValue {
            case "attestedOperation", "attested_operation":
                self.value = try .attestedOperation(associated.decode(
                    WinkBridgeAttestedOperationResponse.self,
                    forKey: .value))
                return
            case "projectedAction", "projected_action":
                self.value = try .projectedAction(associated.decode(
                    WinkBridgeProjectedActionResponse.self,
                    forKey: .value))
                return
            default:
                break
            }
        }
        self.value = try WinkBridgeResponse(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try self.value.encode(to: encoder)
    }
}

extension WinkBridgeAttestedOperationResponse {
    private enum CodingKeys: String, CodingKey {
        case response
        case receipt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.response = try container.decode(
            WinkBridgeResponseCodingBox.self,
            forKey: .response).value
        self.receipt = try container.decode(WinkBridgeOperationReceipt.self, forKey: .receipt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(WinkBridgeResponseCodingBox(self.response), forKey: .response)
        try container.encode(self.receipt, forKey: .receipt)
    }
}

extension WinkBridgeResponse {
    private static let fallbackErrorData = Data(
        #"{"error":{"_0":{"code":"internalError","message":"Failed to encode bridge error response"}}}"#.utf8)

    /// Encode an error envelope for the bridge wire format.
    ///
    /// Never returns empty `Data`. An empty payload cannot be decoded as
    /// `WinkBridgeResponse` and leaves clients with a confusing decode
    /// failure instead of the original error.
    static func encodeError(
        _ envelope: WinkBridgeErrorEnvelope,
        using encoder: JSONEncoder = .winkBridgeEncoder()) -> Data
    {
        self.encodeError(envelope) { response in
            try encoder.encode(response)
        }
    }

    static func encodeError(
        _ envelope: WinkBridgeErrorEnvelope,
        encodeWith encode: (Self) throws -> Data) -> Data
    {
        guard let data = try? encode(.error(envelope)), !data.isEmpty else {
            return self.fallbackErrorData
        }
        return data
    }
}
