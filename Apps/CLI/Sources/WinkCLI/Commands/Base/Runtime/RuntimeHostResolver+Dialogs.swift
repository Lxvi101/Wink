import WinkBridge
import WinkCore

extension RuntimeHostResolver {
    static func remoteDialogCapabilities(
        for handshake: WinkBridgeHandshakeResponse
    ) -> RemoteDialogCapabilities {
        let exactInput =
            handshake.negotiatedVersion >= WinkBridgeConstants.exactDialogInputExecutionVersion &&
            handshake.hostCapabilities?.contains(WinkBridgeHostCapability.exactDialogInputExecution) == true
        let exactForceDismiss =
            handshake.negotiatedVersion >= WinkBridgeConstants.exactForcedDialogDismissExecutionVersion &&
            handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.exactForcedDialogDismissExecution
            ) == true
        let legacyInputFocusPolicy =
            handshake.negotiatedVersion >= WinkBridgeConstants.dialogInputFocusPolicyVersion &&
            handshake.hostCapabilities?.contains(WinkBridgeHostCapability.dialogInputFocusPolicy) == true
        let usesAttestedReceipts =
            handshake.negotiatedVersion >= WinkBridgeConstants.attestedOperationReceiptVersion &&
            handshake.hostCapabilities?.contains(WinkBridgeHostCapability.attestedOperationReceipts) == true
        return RemoteDialogCapabilities(
            systemAlertDiscovery: handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.systemAlertDialogDiscovery
            ) == true,
            backgroundButtonClick: BridgeCapabilityPolicy.supportsOperation(
                .backgroundDialogClickButton,
                for: handshake
            ),
            targetedList: BridgeCapabilityPolicy.supportsOperation(.targetedDialogListElements, for: handshake),
            prepareAction: BridgeCapabilityPolicy.supportsOperation(.prepareDialogAction, for: handshake),
            exactClick: BridgeCapabilityPolicy.supportsOperation(.exactDialogClickButton, for: handshake),
            exactDismiss: BridgeCapabilityPolicy.supportsOperation(.exactDialogDismiss, for: handshake),
            exactInput: exactInput &&
                BridgeCapabilityPolicy.supportsOperation(.exactDialogEnterText, for: handshake),
            backgroundExactInput: usesAttestedReceipts && exactInput &&
                BridgeCapabilityPolicy.supportsOperation(.exactDialogEnterText, for: handshake),
            exactForceDismiss: exactForceDismiss &&
                BridgeCapabilityPolicy.supportsOperation(.exactDialogForceDismiss, for: handshake),
            legacyInputFocusPolicy: legacyInputFocusPolicy &&
                BridgeCapabilityPolicy.supportsOperation(.dialogEnterText, for: handshake),
            exactFileExecution: usesAttestedReceipts &&
                handshake.negotiatedVersion >= WinkBridgeConstants.exactFileDialogExecutionVersion &&
                handshake.hostCapabilities?.contains(WinkBridgeHostCapability.exactFileDialogExecution) == true &&
                handshake.supportedOperations.contains(.dialogHandleFile) &&
                handshake.enabledOperations?.contains(.dialogHandleFile) == true
        )
    }
}
