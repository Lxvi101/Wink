import Foundation
import WinkAutomationKit
import WinkFoundation

@MainActor
extension WinkBridgeServer {
    static func updateScopedMenuBarActionsCapability(
        to resolvedHostCapabilities: inout Set<String>,
        services: any WinkBridgeServiceProviding,
        supportedVersions: ClosedRange<WinkBridgeProtocolVersion>,
        allowedOperations: Set<WinkBridgeOperation>)
    {
        if supportedVersions.upperBound >= WinkBridgeConstants.scopedMenuBarActionsVersion,
           allowedOperations.isSuperset(of: [.prepareMenuBarItem, .clickMenuBarItemNamed]),
           services.menu is any MenuServiceScopedMenuBarPreparationProviding,
           services.menu is any MenuServiceExactLeafActionResultProviding
        {
            resolvedHostCapabilities.insert(WinkBridgeHostCapability.scopedMenuBarActions)
        } else {
            resolvedHostCapabilities.remove(WinkBridgeHostCapability.scopedMenuBarActions)
        }
    }

    static func invalidRequest(for request: WinkBridgeRequest) -> WinkBridgeErrorEnvelope {
        WinkBridgeErrorEnvelope(
            code: .invalidRequest,
            message: "Unexpected request for operation \(request.operation.rawValue)")
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func handleHandshake(
        _ payload: WinkBridgeHandshake,
        peer: WinkBridgePeer?,
        permissions: PermissionsStatus) async throws -> WinkBridgeResponse
    {
        let resolvedBundle = peer?.bundleIdentifier ?? payload.client.bundleIdentifier
        let resolvedTeam = peer?.teamIdentifier ?? payload.client.teamIdentifier
        let operationReceiptAuthority = WinkBridgeRequestContext.operationReceiptAuthority

        guard self.supportedVersions.contains(payload.protocolVersion) else {
            throw WinkBridgeErrorEnvelope(
                code: .versionMismatch,
                message: """
                Bridge protocol \(payload.protocolVersion.major).\(payload.protocolVersion.minor) is not supported by \
                this host. Ask the user to relaunch Wink so the bridge host updates, then retry.
                """)
        }
        if let bundle = resolvedBundle,
           !self.allowlistedBundles.isEmpty,
           !self.allowlistedBundles.contains(bundle)
        {
            throw WinkBridgeErrorEnvelope(code: .unauthorizedClient, message: "Bundle \(bundle) is not authorized")
        }

        if let team = resolvedTeam,
           !self.allowlistedTeams.isEmpty,
           !self.allowlistedTeams.contains(team)
        {
            throw WinkBridgeErrorEnvelope(code: .unauthorizedClient, message: "Team \(team) is not authorized")
        }

        if let uid = peer?.userIdentifier, uid != getuid() {
            throw WinkBridgeErrorEnvelope(
                code: .unauthorizedClient,
                message: "UID \(uid) is not authorized for this listener")
        }

        if let pid = peer?.processIdentifier {
            self.logger.debug("bridge handshake ok pid=\(pid, privacy: .public)")
        }

        let negotiated = min(
            max(payload.protocolVersion, self.supportedVersions.lowerBound),
            self.supportedVersions.upperBound)
        let supportsAttestedOperationReceipts =
            negotiated >= WinkBridgeConstants.attestedOperationReceiptVersion &&
            operationReceiptAuthority != nil &&
            self.hostCapabilities.contains(WinkBridgeHostCapability.desktopActionOutcomeProjection)
        let heldPointerOperations: Set<WinkBridgeOperation> = [
            .createExactWindowHeldPointerOwner,
            .beginExactWindowHeldPointer,
            .releaseExactWindowHeldPointer,
            .revokeExactWindowHeldPointer,
            .disconnectExactWindowHeldPointerOwner,
        ]

        let compatibleOperations = self.handshakeOperations(
            negotiated: negotiated,
            permissions: permissions,
            usesAttestedOperationReceipts: supportsAttestedOperationReceipts)
        var advertisedOps = compatibleOperations.advertised.sorted { $0.rawValue < $1.rawValue }
        var enabledOps = compatibleOperations.enabled
        if (self.services.automation as? any ExactWindowTargetedKeyboardServiceProtocol)?
            .supportsExactWindowTargetedKeyboard != true,
            !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.clipboardGuardedExactWindowHotkeyVersion
        {
            advertisedOps.removeAll { $0 == .exactWindowTargetedHotkey }
            enabledOps.remove(.exactWindowTargetedHotkey)
        }
        if !supportsAttestedOperationReceipts {
            advertisedOps.removeAll { $0 == .exactWindowDrag }
            enabledOps.remove(.exactWindowDrag)
        }
        let clientCapabilities = Set(payload.clientCapabilities ?? [])
        let supportsScopedMenuBarActions = supportsAttestedOperationReceipts &&
            negotiated >= WinkBridgeConstants.scopedMenuBarActionsVersion &&
            clientCapabilities.contains(WinkBridgeClientCapability.scopedMenuBarActions) &&
            self.hostCapabilities.contains(WinkBridgeHostCapability.scopedMenuBarActions)
        if !supportsScopedMenuBarActions {
            advertisedOps.removeAll { $0 == .prepareMenuBarItem }
            enabledOps.remove(.prepareMenuBarItem)
        }
        let browserHandoffOperations: Set<WinkBridgeOperation> = [
            .browserStatus,
            .browserConnect,
            .browserExecute,
            .browserSessionBootstrap,
            .browserSessionControl,
        ]
        let supportsBrowserConnectionHandoff =
            supportsAttestedOperationReceipts &&
            negotiated >= WinkBridgeConstants.browserConnectionHandoffVersion &&
            clientCapabilities.contains(WinkBridgeClientCapability.browserConnectionHandoff) &&
            self.hostCapabilities.contains(WinkBridgeHostCapability.browserConnectionHandoff) &&
            self.browserSessionBootstrapProvider?.supportsBrowserSessionBootstrap == true &&
            browserHandoffOperations.isSubset(of: Set(advertisedOps)) &&
            browserHandoffOperations.isSubset(of: enabledOps) &&
            (peer?.isApprovedBrowserHandoffCaller() ?? false)
        if !supportsBrowserConnectionHandoff {
            advertisedOps.removeAll { $0 == .browserSessionBootstrap || $0 == .browserSessionControl }
            enabledOps.remove(.browserSessionBootstrap)
            enabledOps.remove(.browserSessionControl)
        }
        if !clientCapabilities.contains(WinkBridgeClientCapability.producerBoundSnapshotReferences) {
            advertisedOps.removeAll { $0 == .ownsSnapshot }
            enabledOps.remove(.ownsSnapshot)
        }
        if (try? self.requireCertificationCaller(peer)) == nil {
            advertisedOps.removeAll {
                $0 == .observeProcessGeneration || $0 == .certificationProducerAttestation
            }
            enabledOps.remove(.observeProcessGeneration)
            enabledOps.remove(.certificationProducerAttestation)
        }
        if negotiated >= WinkBridgeConstants.exactWindowHeldPointerLifecycleVersion,
           !supportsAttestedOperationReceipts
        {
            advertisedOps.removeAll { heldPointerOperations.contains($0) }
            enabledOps.subtract(heldPointerOperations)
        }
        if negotiated >= WinkBridgeConstants.attestedOperationReceiptVersion,
           !advertisedOps.contains(.listWindows)
        {
            advertisedOps.removeAll { $0 == .focusWindow }
            enabledOps.remove(.focusWindow)
        }
        if negotiated >= WinkBridgeConstants.attestedOperationReceiptVersion,
           !enabledOps.contains(.listWindows)
        {
            enabledOps.remove(.focusWindow)
        }
        if negotiated >= WinkBridgeConstants.attestedOperationReceiptVersion,
           !advertisedOps.contains(.findApplication)
        {
            advertisedOps.removeAll { $0 == .activateApplication }
            enabledOps.remove(.activateApplication)
        }
        if negotiated >= WinkBridgeConstants.attestedOperationReceiptVersion,
           !enabledOps.contains(.findApplication)
        {
            enabledOps.remove(.activateApplication)
        }
        var permissionTags = Dictionary(
            uniqueKeysWithValues: advertisedOps.map { op in
                (op.rawValue, Array(op.requiredPermissions).sorted { $0.rawValue < $1.rawValue })
            })
        Self.applyExactDialogInputPermissionContract(
            supportsAttestedOperationReceipts: supportsAttestedOperationReceipts,
            advertisedOperations: advertisedOps,
            permissions: permissions,
            enabledOperations: &enabledOps,
            permissionTags: &permissionTags)
        Self.applyExactFileDialogPermissionContract(
            supportsAttestedOperationReceipts: supportsAttestedOperationReceipts,
            advertisedOperations: advertisedOps,
            permissions: permissions,
            enabledOperations: &enabledOps,
            permissionTags: &permissionTags)
        let requestAwareTargetedClickVersion = WinkBridgeProtocolVersion(major: 1, minor: 9)
        if negotiated < requestAwareTargetedClickVersion,
           advertisedOps.contains(.targetedClick)
        {
            // Protocol 1.6...1.8 exposed only synthetic targeted clicks. Preserve that
            // permission contract for old clients even though 1.9 can use AX per request.
            permissionTags[WinkBridgeOperation.targetedClick.rawValue] = [.postEvent]
            if !permissions.postEvent {
                enabledOps.remove(.targetedClick)
            } else {
                enabledOps.insert(.targetedClick)
            }
        }

        self.logger.debug(
            """
            Handshake advertised=\(advertisedOps.count, privacy: .public) \
            enabled=\(enabledOps.count, privacy: .public) \
            tags=\(permissionTags.count, privacy: .public)
            """)

        var advertisedCapabilities = self.hostCapabilities
        if !supportsScopedMenuBarActions ||
            !Set([WinkBridgeOperation.prepareMenuBarItem, .clickMenuBarItemNamed]).isSubset(of: advertisedOps)
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.scopedMenuBarActions)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.exactFileDialogExecutionVersion ||
            !self.services.dialogs.supportsExactFileDialogExecution ||
            !advertisedOps.contains(.dialogHandleFile) || !enabledOps.contains(.dialogHandleFile)
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.exactFileDialogExecution)
        }
        if !supportsBrowserConnectionHandoff {
            advertisedCapabilities.remove(WinkBridgeHostCapability.browserConnectionHandoff)
        }
        let browserOperations: Set<WinkBridgeOperation> = [
            .browserStatus,
            .browserConnect,
            .browserDisconnect,
            .browserExecute,
        ]
        if !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.nativeBrowserConnectionBindingVersion ||
            (self.services as? any WinkBridgeBrowserConnectionResultProviding)?
            .supportsNativeBrowserConnectionBinding != true ||
            !browserOperations.isSubset(of: Set(advertisedOps))
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.nativeBrowserConnectionBinding)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.producerBoundSnapshotReferencesVersion ||
            !clientCapabilities.contains(WinkBridgeClientCapability.producerBoundSnapshotReferences) ||
            !self.services.snapshots.supportsProducerBoundSnapshotReferences ||
            !advertisedOps.contains(.ownsSnapshot)
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.producerBoundSnapshotReferences)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.targetedClickAccessibilityValueDeliveryVersion ||
            !clientCapabilities.contains(WinkBridgeClientCapability.targetedClickAccessibilityValueDelivery) ||
            (self.services.automation as? any TargetedClickServiceProtocol)?
            .supportsTargetedClickAccessibilityValueDelivery != true ||
            !advertisedOps.contains(.targetedClick)
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.targetedClickAccessibilityValueDelivery)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.statelessClickVariantVersion ||
            (self.services.automation as? any TargetedClickServiceProtocol)?.supportsStatelessClickVariants != true ||
            !advertisedOps.contains(.targetedClick) ||
            !advertisedOps.contains(.exactWindowTargetedClick)
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.statelessClickVariants)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.exactWindowHeldPointerLifecycleVersion ||
            (self.services.automation as? any ExactWindowHeldPointerLifecycleServiceProtocol)?
            .supportsExactWindowHeldPointerLifecycle != true ||
            !heldPointerOperations.isSubset(of: advertisedOps)
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.exactWindowHeldPointerLifecycle)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.exactWindowDragVersion ||
            !advertisedOps.contains(.exactWindowDrag) ||
            (self.services.automation as? any ExactWindowDragServiceProtocol)?.supportsExactWindowDrag != true
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.exactWindowDrag)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.agentExecutionTraceVersion ||
            !advertisedOps.contains(.agentExecutionTrace) ||
            !enabledOps.contains(.agentExecutionTrace)
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.agentExecutionTrace)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.processGenerationObservationVersion ||
            !advertisedOps.contains(.observeProcessGeneration) ||
            !enabledOps.contains(.observeProcessGeneration)
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.processGenerationObservation)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.certificationProducerAttestationVersion ||
            !advertisedOps.contains(.certificationProducerAttestation) ||
            !enabledOps.contains(.certificationProducerAttestation)
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.certificationProducerAttestation)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.setValueResultTargetBindingVersion ||
            (self.services.automation as? any ElementActionAutomationServiceProtocol)?
            .supportsSetValueResultTargetBinding != true ||
            !advertisedOps.contains(.setValue)
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.setValueResultTargetBinding)
        }
        if !supportsAttestedOperationReceipts || negotiated < WinkBridgeConstants.textSelectionVersion ||
            (self.services.automation as? any ElementActionAutomationServiceProtocol)?.supportsTextSelection != true ||
            !advertisedOps.contains(.selectText)
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.textSelection)
        }
        let elementMutationOperations: Set<WinkBridgeOperation> = [.setValue, .selectText, .performAction]
        if !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.processGenerationBoundElementMutationsVersion ||
            !(self.services.automation is any UIAutomationActionOutcomeProviding) ||
            (self.services.automation as? any ElementActionAutomationServiceProtocol)?
            .supportsProcessGenerationBoundElementMutations != true ||
            elementMutationOperations.isDisjoint(with: advertisedOps)
        {
            advertisedCapabilities.remove(
                WinkBridgeHostCapability.processGenerationBoundElementMutations)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.composedInputParityVersion ||
            !self.services.snapshots.supportsSnapshotMutationLeases ||
            (self.services.automation as? any ForegroundModifierClickServiceProtocol)?
            .supportsForegroundModifierClickSnapshotLease != true ||
            !advertisedOps.contains(.foregroundModifierClick) ||
            !enabledOps.contains(.foregroundModifierClick)
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.foregroundModifierClickSnapshotLease)
        }
        self.applyRequestPinnedExactWindowScrollCapability(
            supportsAttestedOperationReceipts: supportsAttestedOperationReceipts,
            negotiated: negotiated,
            advertisedOperations: advertisedOps,
            enabledOperations: enabledOps,
            advertisedCapabilities: &advertisedCapabilities)
        if !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.compositeTypeDeliveryVersion ||
            (self.services.automation as? any UIAutomationActionOutcomeProviding) == nil ||
            (self.services.automation as? any CompositeTypeDeliveryServiceProtocol)?
            .supportsExactWindowCompositeTypeDelivery != true ||
            !advertisedOps.contains(where: {
                [.targetedTypeActions, .exactWindowTargetedTypeActions, .exactWindowPixelFocusType].contains($0)
            })
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.compositeTypeDelivery)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.clipboardGuardedExactWindowHotkeyVersion ||
            (self.services.automation as? any ClipboardGuardedExactWindowHotkeyServiceProtocol)?
            .supportsClipboardGuardedExactWindowHotkeys != true ||
            !advertisedOps.contains(.exactWindowTargetedHotkey) ||
            !enabledOps.contains(.exactWindowTargetedHotkey)
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.clipboardGuardedExactWindowHotkeys)
        }
        if supportsAttestedOperationReceipts {
            advertisedCapabilities.insert(WinkBridgeHostCapability.attestedOperationReceipts)
        }
        if !advertisedCapabilities.contains(WinkBridgeHostCapability.clipboardGuardedExactWindowHotkeys) ||
            negotiated < WinkBridgeConstants.preparedClipboardGuardedExactWindowHotkeyVersion ||
            (self.services.automation as? any PreparedClipboardGuardedExactWindowHotkeyServiceProtocol)?
            .supportsPreparedClipboardGuardedExactWindowHotkeys != true
        {
            advertisedCapabilities.remove(WinkBridgeHostCapability.preparedClipboardGuardedExactWindowHotkeys)
        }
        let operationSessionAttestation: WinkBridgeOperationSessionAttestation?
        if supportsAttestedOperationReceipts {
            guard let peer,
                  let clientInstanceID = payload.operationClientInstanceID
            else {
                throw WinkBridgeErrorEnvelope(
                    code: .unauthorizedClient,
                    message: "Protocol 1.29 requires a peer-bound operation client instance")
            }
            do {
                operationSessionAttestation = try await operationReceiptAuthority?.createSession(
                    clientInstanceID: clientInstanceID,
                    peer: peer,
                    negotiatedCapabilities: .init(
                        protocolVersion: negotiated,
                        statelessClickVariants: advertisedCapabilities.contains(
                            WinkBridgeHostCapability.statelessClickVariants),
                        exactWindowHeldPointerLifecycle: advertisedCapabilities.contains(
                            WinkBridgeHostCapability.exactWindowHeldPointerLifecycle),
                        exactWindowDrag: advertisedCapabilities.contains(WinkBridgeHostCapability.exactWindowDrag),
                        nativeBrowserConnectionBinding: advertisedCapabilities.contains(
                            WinkBridgeHostCapability.nativeBrowserConnectionBinding),
                        browserConnectionHandoff: advertisedCapabilities.contains(
                            WinkBridgeHostCapability.browserConnectionHandoff),
                        producerBoundSnapshotReferences: advertisedCapabilities.contains(
                            WinkBridgeHostCapability.producerBoundSnapshotReferences),
                        scopedMenuBarActions: advertisedCapabilities.contains(
                            WinkBridgeHostCapability.scopedMenuBarActions),
                        targetedClickAccessibilityValueDelivery: advertisedCapabilities.contains(
                            WinkBridgeHostCapability.targetedClickAccessibilityValueDelivery),
                        requestPinnedExactWindowScrollReceipt: advertisedCapabilities.contains(
                            WinkBridgeHostCapability.requestPinnedExactWindowScrollReceipt),
                        backgroundCoordinateScroll: advertisedCapabilities.contains(
                            WinkBridgeHostCapability.backgroundCoordinateScroll),
                        compositeTypeDelivery: advertisedCapabilities.contains(
                            WinkBridgeHostCapability.compositeTypeDelivery),
                        exactFileDialogExecution: advertisedCapabilities.contains(
                            WinkBridgeHostCapability.exactFileDialogExecution),
                        clipboardGuardedExactWindowHotkeys: advertisedCapabilities.contains(
                            WinkBridgeHostCapability.clipboardGuardedExactWindowHotkeys),
                        preparedClipboardGuardedExactWindowHotkeys: advertisedCapabilities.contains(
                            WinkBridgeHostCapability.preparedClipboardGuardedExactWindowHotkeys),
                        processGenerationBoundElementMutations: advertisedCapabilities.contains(
                            WinkBridgeHostCapability.processGenerationBoundElementMutations),
                        setValueVerification: WinkBridgeNegotiatedSessionCapabilities.offersSetValueVerification(
                            clientCapabilities, negotiatedVersion: negotiated),
                        screenCaptureKitOwnershipDiagnostics: clientCapabilities.contains(
                            WinkBridgeClientCapability.screenCaptureKitOwnershipDiagnostics)),
                    replacing: payload.replacingOperationSessionID)
                self.clearReceiptlessNegotiation(peer: peer)
            } catch let error as WinkBridgeOperationReceiptError {
                let code: WinkBridgeErrorCode = switch error {
                case .operationSessionMismatch:
                    .invalidRequest
                case .operationSessionRegistryExhausted, .archiveWriteFailed,
                     .invalidOperationSessionConfiguration:
                    .serverBusy
                case .peerIdentityMismatch, .clientIdentityMismatch:
                    .unauthorizedClient
                default:
                    .internalError
                }
                throw WinkBridgeErrorEnvelope(
                    code: code,
                    message: error.localizedDescription,
                    details: "\(error)",
                    context: "bridge_operation_session:handshake")
            }
        } else {
            operationSessionAttestation = nil
            self.recordReceiptlessNegotiation(peer: peer, protocolVersion: negotiated)
        }
        let response = WinkBridgeHandshakeResponse(
            negotiatedVersion: negotiated,
            hostKind: self.hostKind,
            build: WinkBridgeConstants.buildIdentifier,
            supportedOperations: advertisedOps,
            permissions: permissions,
            enabledOperations: Array(enabledOps).sorted { $0.rawValue < $1.rawValue },
            permissionTags: permissionTags,
            hostIdentity: self.hostIdentity,
            hostCapabilities: advertisedCapabilities.sorted(),
            screenCaptureKitReadiness: self.screenCaptureKitReadiness,
            operationAttestation: supportsAttestedOperationReceipts
                ? operationReceiptAuthority?.attestation
                : nil,
            operationSessionAttestation: operationSessionAttestation)
        return .handshake(response)
    }

    private static func applyExactFileDialogPermissionContract(
        supportsAttestedOperationReceipts: Bool,
        advertisedOperations: [WinkBridgeOperation],
        permissions: PermissionsStatus,
        enabledOperations: inout Set<WinkBridgeOperation>,
        permissionTags: inout [String: [WinkBridgePermissionKind]])
    {
        guard supportsAttestedOperationReceipts, advertisedOperations.contains(.dialogHandleFile) else { return }
        let requiredPermissions: Set<WinkBridgePermissionKind> = [.accessibility, .postEvent]
        permissionTags[WinkBridgeOperation.dialogHandleFile.rawValue] = requiredPermissions
            .sorted { $0.rawValue < $1.rawValue }
        if requiredPermissions.isSubset(of: self.grantedPermissions(from: permissions)) {
            enabledOperations.insert(.dialogHandleFile)
        } else {
            enabledOperations.remove(.dialogHandleFile)
        }
    }

    private static func applyExactDialogInputPermissionContract(
        supportsAttestedOperationReceipts: Bool,
        advertisedOperations: [WinkBridgeOperation],
        permissions: PermissionsStatus,
        enabledOperations: inout Set<WinkBridgeOperation>,
        permissionTags: inout [String: [WinkBridgePermissionKind]])
    {
        guard advertisedOperations.contains(.exactDialogEnterText) else { return }

        let requiredPermissions: Set<WinkBridgePermissionKind> = supportsAttestedOperationReceipts
            ? [.accessibility]
            : [.accessibility, .postEvent]
        permissionTags[WinkBridgeOperation.exactDialogEnterText.rawValue] = requiredPermissions
            .sorted { $0.rawValue < $1.rawValue }
        if requiredPermissions.isSubset(of: self.grantedPermissions(from: permissions)) {
            enabledOperations.insert(.exactDialogEnterText)
        } else {
            enabledOperations.remove(.exactDialogEnterText)
        }
    }

    private func applyRequestPinnedExactWindowScrollCapability(
        supportsAttestedOperationReceipts: Bool,
        negotiated: WinkBridgeProtocolVersion,
        advertisedOperations: [WinkBridgeOperation],
        enabledOperations: Set<WinkBridgeOperation>,
        advertisedCapabilities: inout Set<String>)
    {
        guard supportsAttestedOperationReceipts,
              negotiated >= WinkBridgeConstants.requestPinnedExactWindowScrollReceiptVersion,
              (self.services.automation as? any UIAutomationActionOutcomeProviding)?
                  .supportsRequestPinnedExactWindowScrollReceipt == true,
                  advertisedOperations.contains(.targetedScroll),
                  enabledOperations.contains(.targetedScroll)
        else {
            advertisedCapabilities.remove(WinkBridgeHostCapability.requestPinnedExactWindowScrollReceipt)
            advertisedCapabilities.remove(WinkBridgeHostCapability.backgroundCoordinateScroll)
            return
        }
        Self.updateBackgroundCoordinateScrollCapability(
            capabilities: &advertisedCapabilities, version: negotiated, automation: self.services.automation)
    }

    static func updateBackgroundCoordinateScrollCapability(
        capabilities: inout Set<String>,
        version: WinkBridgeProtocolVersion,
        automation: any UIAutomationServiceProtocol)
    {
        if version >= WinkBridgeConstants.backgroundCoordinateScrollVersion,
           capabilities.contains(WinkBridgeHostCapability.requestPinnedExactWindowScrollReceipt),
           (automation as? any UIAutomationActionOutcomeProviding)?.supportsBackgroundCoordinateScroll == true
        {
            capabilities.insert(WinkBridgeHostCapability.backgroundCoordinateScroll)
        } else {
            capabilities.remove(WinkBridgeHostCapability.backgroundCoordinateScroll)
        }
    }

    private func handshakeOperations(
        negotiated: WinkBridgeProtocolVersion,
        permissions: PermissionsStatus,
        usesAttestedOperationReceipts: Bool)
        -> (advertised: [WinkBridgeOperation], enabled: Set<WinkBridgeOperation>)
    {
        let advertised = self.operationsCompatibleWithNegotiatedVersion(
            self.allowedOperationsToAdvertise(),
            negotiated,
            usesAttestedOperationReceipts: usesAttestedOperationReceipts)
        let enabled = self.operationsCompatibleWithNegotiatedVersion(
            self.effectiveAllowedOperations(permissions: permissions),
            negotiated,
            usesAttestedOperationReceipts: usesAttestedOperationReceipts)
        return (Array(advertised), enabled)
    }

    func operationsCompatibleWithNegotiatedVersion(
        _ operations: Set<WinkBridgeOperation>,
        _ negotiated: WinkBridgeProtocolVersion,
        usesAttestedOperationReceipts: Bool) -> Set<WinkBridgeOperation>
    {
        var compatible = WinkBridgeOperation.compatible(operations, with: negotiated)
        if self.supportedVersions.upperBound >=
            WinkBridgeConstants.processGenerationBoundElementMutationsVersion,
            !usesAttestedOperationReceipts ||
            negotiated < WinkBridgeConstants.processGenerationBoundElementMutationsVersion
        {
            compatible.remove(.setValue)
            compatible.remove(.selectText)
            compatible.remove(.performAction)
        }
        if !usesAttestedOperationReceipts {
            compatible.remove(.observeProcessGeneration)
            compatible.remove(.certificationProducerAttestation)
        }
        if usesAttestedOperationReceipts,
           !self.services.dialogs.supportsBackgroundExactDialogInput
        {
            compatible.remove(.exactDialogEnterText)
        }
        if usesAttestedOperationReceipts,
           negotiated < WinkBridgeConstants.exactFileDialogExecutionVersion ||
           !self.services.dialogs.supportsExactFileDialogExecution
        {
            compatible.remove(.dialogHandleFile)
        }
        return compatible
    }

    func allowedOperationsToAdvertise() -> Set<WinkBridgeOperation> {
        var operations = self.allowedOperations
        // Retain the wire enum for old-client decoding, but current hosts never advertise or execute the probe.
        operations.remove(._appleScriptProbe)
        if self.daemonControl == nil {
            operations.remove(.daemonStatus)
            operations.remove(.daemonStop)
            operations.remove(.relaunchApplicationWithOptions)
        }
        if self.servingSocketPath == nil || self.agentExecutionRunner == nil {
            operations.remove(.agentExecutionTrace)
        }
        if (self.services.automation as? any TargetedHotkeyServiceProtocol)?.supportsTargetedHotkeys != true {
            operations.remove(.targetedHotkey)
        }
        if (self.services.automation as? any TargetedTypeServiceProtocol)?.supportsTargetedTypeActions != true {
            operations.remove(.targetedTypeActions)
        }
        if (self.services.automation as? any TargetedClickServiceProtocol)?.supportsTargetedClicks != true {
            operations.remove(.targetedClick)
        }
        if (self.services.automation as? any ExactWindowTargetedClickServiceProtocol)?
            .supportsExactWindowTargetedClicks != true
        {
            operations.remove(.exactWindowTargetedClick)
        }
        if self.services.automation as? any ElementActionAutomationServiceProtocol == nil ||
            (self.supportedVersions.upperBound >=
                WinkBridgeConstants.processGenerationBoundElementMutationsVersion &&
                !Self.supportsProcessGenerationBoundElementMutationProvider(self.services.automation))
        {
            operations.remove(.setValue)
            operations.remove(.selectText)
            operations.remove(.performAction)
        }
        operations = Set(operations.filter {
            ($0 != .selectText ||
                (self.services.automation as? any ElementActionAutomationServiceProtocol)?
                .supportsTextSelection == true) &&
                ($0 != .setValue ||
                    self.supportedVersions.upperBound <
                    WinkBridgeConstants.processGenerationBoundElementMutationsVersion ||
                    (self.services.automation as? any ElementActionAutomationServiceProtocol)?
                    .supportsSetValueResultTargetBinding == true)
        })
        if self.services.automation as? any TargetedFocusedElementServiceProtocol == nil {
            operations.remove(.getFocusedElement)
        }
        if (self.services.automation as? any ExactWindowTargetedKeyboardServiceProtocol)?
            .supportsExactWindowTargetedKeyboard != true
        {
            operations.remove(.exactWindowTargetedTypeActions)
            if (self.services.automation as? any ClipboardGuardedExactWindowHotkeyServiceProtocol)?
                .supportsClipboardGuardedExactWindowHotkeys != true
            {
                operations.remove(.exactWindowTargetedHotkey)
            }
        }
        if (self.services.automation as? any ExactWindowPixelFocusTypingServiceProtocol)?
            .supportsExactWindowPixelFocusTyping != true
        {
            operations.remove(.exactWindowPixelFocusType)
        }
        if !self.services.snapshots.supportsSnapshotMutationLeases ||
            (self.services.automation as? any ForegroundModifierClickServiceProtocol)?
            .supportsForegroundModifierClick != true ||
            (self.services.automation as? any ForegroundModifierClickServiceProtocol)?
            .supportsForegroundModifierClickSnapshotLease != true
        {
            operations.remove(.foregroundModifierClick)
        }
        if (self.services.automation as? any ExactWindowHeldPointerLifecycleServiceProtocol)?
            .supportsExactWindowHeldPointerLifecycle != true
        {
            operations.subtract([
                .createExactWindowHeldPointerOwner,
                .beginExactWindowHeldPointer,
                .releaseExactWindowHeldPointer,
                .revokeExactWindowHeldPointer,
                .disconnectExactWindowHeldPointerOwner,
            ])
        }
        if (self.services.automation as? any ExactWindowDragServiceProtocol)?.supportsExactWindowDrag != true {
            operations.remove(.exactWindowDrag)
        }
        if !self.services.snapshots.supportsImplicitLatestSnapshotInvalidation {
            operations.remove(.invalidateImplicitLatestSnapshot)
        }
        if !self.services.snapshots.supportsSnapshotMutationLeases {
            operations.remove(.beginSnapshotMutation)
            operations.remove(.finishSnapshotMutation)
        }
        if !self.services.snapshots.supportsProducerBoundSnapshotReferences {
            operations.remove(.ownsSnapshot)
        }
        if !self.services.snapshots.supportsAtomicObservationSnapshotPublication {
            operations.remove(.storeObservationSnapshot)
        }
        if !self.services.applications.supportsApplicationLaunchOptions {
            operations.remove(.launchApplicationWithOptions)
        }
        if !self.services.applications.supportsApplicationRelaunch {
            operations.remove(.relaunchApplicationWithOptions)
        }
        if !self.services.applications.supportsProcessGenerationPinnedApplicationQuit {
            operations.remove(.quitApplication)
        }
        return operations
    }

    static func supportsProcessGenerationBoundElementMutationProvider(
        _ automation: any UIAutomationServiceProtocol) -> Bool
    {
        automation is any UIAutomationActionOutcomeProviding &&
            (automation as? any ElementActionAutomationServiceProtocol)?
            .supportsProcessGenerationBoundElementMutations == true
    }

    func effectiveAllowedOperations(permissions: PermissionsStatus) -> Set<WinkBridgeOperation> {
        let granted = Self.grantedPermissions(from: permissions)

        var operations = Set(
            self.allowedOperationsToAdvertise().filter { operation in
                operation.requiredPermissions.isSubset(of: granted)
            })

        // Every targeted click needs Accessibility for element/window validation. Variants that
        // use exact-window routed events receive their additional PostEvent check per request.
        if !permissions.accessibility {
            operations.remove(.targetedClick)
            operations.remove(.exactWindowTargetedClick)
        }
        return operations
    }

    func effectiveAllowedOperations(
        for request: WinkBridgeRequest,
        permissions: PermissionsStatus) -> Set<WinkBridgeOperation>
    {
        var operations = self.effectiveAllowedOperations(permissions: permissions)
        let operation = request.operation
        let advertisedOperations = self.allowedOperationsToAdvertise()
        if request.requiresExactFileDialogExecution {
            if !self.services.dialogs.supportsExactFileDialogExecution ||
                !permissions.accessibility || !permissions.postEvent
            {
                operations.remove(operation)
            }
        } else if WinkBridgeRequestContext.usesAttestedOperationResultSemantics,
                  operation == .exactDialogEnterText
        {
            if advertisedOperations.contains(operation),
               self.services.dialogs.supportsBackgroundExactDialogInput,
               permissions.accessibility
            {
                // Protocol 1.29 executes exact dialog input through AXValue, so only its
                // legacy PostEvent requirement is waived. Host allowlisting and service
                // advertisement remain authoritative.
                operations.insert(operation)
            } else {
                operations.remove(operation)
            }
        } else if operation == .exactDialogEnterText,
                  !permissions.accessibility || !permissions.postEvent
        {
            operations.remove(operation)
        }
        return operations.intersection(advertisedOperations)
    }

    static func grantedPermissions(from permissions: PermissionsStatus) -> Set<WinkBridgePermissionKind> {
        var granted: Set<WinkBridgePermissionKind> = []
        if permissions.screenRecording {
            granted.insert(.screenRecording)
        }
        if permissions.accessibility {
            granted.insert(.accessibility)
        }
        if permissions.postEvent {
            granted.insert(.postEvent)
        }

        return granted
    }

    func currentPermissions() -> PermissionsStatus {
        let permissions = self.permissionStatusEvaluator(false)
        return PermissionsStatus(
            screenRecording: permissions.screenRecording,
            accessibility: permissions.accessibility,
            appleScript: false,
            postEvent: permissions.postEvent)
    }

    static func bridgePermission(for error: WinkError) -> WinkBridgePermissionKind? {
        switch error {
        case .permissionDeniedAccessibility:
            .accessibility
        case .permissionDeniedScreenRecording:
            .screenRecording
        case .permissionDeniedEventSynthesizing:
            .postEvent
        default:
            nil
        }
    }

    func receiptlessProtocolVersion(for peer: WinkBridgePeer?) -> WinkBridgeProtocolVersion? {
        self.pruneReceiptlessNegotiations()
        guard let liveIdentity = peer?.liveIdentity,
              self.processStartIdentityProvider(liveIdentity.processIdentifier) ==
              liveIdentity.processStartIdentity
        else { return nil }
        return self.receiptlessNegotiations[liveIdentity]?.protocolVersion
    }

    private func recordReceiptlessNegotiation(
        peer: WinkBridgePeer?,
        protocolVersion: WinkBridgeProtocolVersion)
    {
        guard let liveIdentity = peer?.liveIdentity,
              self.processStartIdentityProvider(liveIdentity.processIdentifier) ==
              liveIdentity.processStartIdentity
        else { return }
        self.pruneReceiptlessNegotiations()
        if self.receiptlessNegotiations.count >= 1024,
           self.receiptlessNegotiations[liveIdentity] == nil,
           let oldest = self.receiptlessNegotiations.min(by: { $0.value.recordedAt < $1.value.recordedAt })?.key
        {
            self.receiptlessNegotiations.removeValue(forKey: oldest)
        }
        self.receiptlessNegotiations[liveIdentity] = WinkBridgeReceiptlessNegotiation(
            protocolVersion: protocolVersion,
            recordedAt: ContinuousClock.now)
    }

    private func clearReceiptlessNegotiation(peer: WinkBridgePeer?) {
        guard let liveIdentity = peer?.liveIdentity else { return }
        self.receiptlessNegotiations.removeValue(forKey: liveIdentity)
    }

    private func pruneReceiptlessNegotiations() {
        self.receiptlessNegotiations = self.receiptlessNegotiations.filter { liveIdentity, _ in
            self.processStartIdentityProvider(liveIdentity.processIdentifier) == liveIdentity.processStartIdentity
        }
    }
}
