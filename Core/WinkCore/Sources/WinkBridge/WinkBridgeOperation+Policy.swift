import Foundation

extension WinkBridgeOperation {
    var mutatesDesktop: Bool {
        WinkBridgeOperationResultSemantics.contract(for: self).completion.mutatesDesktop
    }

    /// Whether Wink's concrete native service retains desktop-lane ownership through its dispatch leaf.
    ///
    /// Bridge routing consults this policy together with the service provider's ownership claim. Keeping the
    /// exhaustive operation list here prevents native host assemblies and request routing from drifting apart.
    public var nativeServiceOwnsDesktopOperationLane: Bool {
        WinkBridgeOperationResultSemantics.operationPolicy(for: self)
            .lane.nativeOwnership == .service
    }

    public static let nativeDesktopOperationLaneOperations: Set<WinkBridgeOperation> =
        Set(Self.allCases.filter(\.nativeServiceOwnsDesktopOperationLane))

    var responseCarriesPostMutationWindowState: Bool {
        WinkBridgeOperationResultSemantics.operationPolicy(for: self)
            .windowResponseProof == .postMutationState
    }

    /// The operation's static/current TCC permissions. Protocol- and request-specific modifiers stay server-owned.
    public var requiredPermissions: Set<WinkBridgePermissionKind> {
        WinkBridgeOperationResultSemantics.operationPolicy(for: self).requiredPermissions
    }

    /// Operations enabled by default for remote helper hosts.
    public static let remoteDefaultAllowlist: Set<WinkBridgeOperation> = [
        .permissionsStatus,
        .requestPostEventPermission,
        .daemonStatus,
        .daemonStop,
        .agentExecutionTrace,
        .observeProcessGeneration,
        .certificationProducerAttestation,
        .browserStatus,
        .browserConnect,
        .browserDisconnect,
        .browserExecute,
        .browserSessionBootstrap,
        .browserSessionControl,
        .captureScreen,
        .captureWindow,
        .captureFrontmost,
        .captureArea,
        .detectElements,
        .inspectAccessibilityTree,
        .getFocusedElement,
        .desktopObservation,
        .click,
        .type,
        .typeActions,
        .setValue,
        .selectText,
        .performAction,
        .scroll,
        .targetedScroll,
        .hotkey,
        .targetedHotkey,
        .exactWindowTargetedHotkey,
        .createExactWindowHeldPointerOwner,
        .beginExactWindowHeldPointer,
        .exactWindowDrag,
        .releaseExactWindowHeldPointer,
        .revokeExactWindowHeldPointer,
        .disconnectExactWindowHeldPointerOwner,
        .targetedTypeActions,
        .exactWindowTargetedTypeActions,
        .exactWindowPixelFocusType,
        .foregroundModifierClick,
        .targetedClick,
        .exactWindowTargetedClick,
        .swipe,
        .drag,
        .moveMouse,
        .waitForElement,
        .listWindows,
        .focusWindow,
        .moveWindow,
        .resizeWindow,
        .setWindowBounds,
        .closeWindow,
        .backgroundCloseWindow,
        .minimizeWindow,
        .restoreWindow,
        .maximizeWindow,
        .getFocusedWindow,
        .listApplications,
        .findApplication,
        .getFrontmostApplication,
        .isApplicationRunning,
        .launchApplication,
        .launchApplicationWithOptions,
        .relaunchApplicationWithOptions,
        .activateApplication,
        .quitApplication,
        .hideApplication,
        .hideOtherApplications,
        .showAllApplications,
        .listMenus,
        .listFrontmostMenus,
        .clickMenuItem,
        .clickMenuItemByName,
        .listMenuExtras,
        .clickMenuExtra,
        .menuExtraOpenMenuFrame,
        .listMenuBarItems,
        .prepareMenuBarItem,
        .clickMenuBarItemNamed,
        .clickMenuBarItemIndex,
        .listDockItems,
        .launchDockItem,
        .rightClickDockItem,
        .hideDock,
        .showDock,
        .isDockHidden,
        .findDockItem,
        .dialogFindActive,
        .dialogClickButton,
        .backgroundDialogClickButton,
        .dialogEnterText,
        .dialogHandleFile,
        .dialogDismiss,
        .dialogListElements,
        .targetedDialogListElements,
        .prepareDialogAction,
        .exactDialogClickButton,
        .exactDialogDismiss,
        .exactDialogEnterText,
        .exactDialogForceDismiss,
        .createSnapshot,
        .storeDetectionResult,
        .getDetectionResult,
        .ownsSnapshot,
        .storeScreenshot,
        .storeObservationSnapshot,
        .storeAnnotatedScreenshot,
        .listSnapshots,
        .getMostRecentSnapshot,
        .invalidateImplicitLatestSnapshot,
        .beginSnapshotMutation,
        .finishSnapshotMutation,
        .cleanSnapshot,
        .cleanSnapshotsOlderThan,
        .cleanAllSnapshots,
    ]

    /// Native operations exposed by an embedded host.
    ///
    /// Embedded hosts intentionally do not acquire browser, daemon-control, or interactive permission-prompt
    /// responsibilities. The containing app remains the owner of those product-specific surfaces.
    public static let embeddedDefaultAllowlist: Set<WinkBridgeOperation> =
        WinkBridgeOperation.remoteDefaultAllowlist.subtracting([
            .agentExecutionTrace,
            .requestPostEventPermission,
            .daemonStatus,
            .daemonStop,
            .browserStatus,
            .browserConnect,
            .browserDisconnect,
            .browserExecute,
            .browserSessionBootstrap,
            .browserSessionControl,
        ])
}
