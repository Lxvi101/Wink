import WinkFoundation

extension WinkBridgeServer {
    func validateExactFileDialogExecutionAccess(_ request: WinkBridgeRequest) throws {
        guard request.requiresExactFileDialogExecution else { return }
        guard self.services.dialogs.supportsExactFileDialogExecution,
              WinkBridgeRequestContext.usesAttestedOperationResultSemantics,
              let session = WinkBridgeRequestContext.negotiatedSessionCapabilities,
              session.protocolVersion >= WinkBridgeConstants.exactFileDialogExecutionVersion,
              session.exactFileDialogExecution
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "This Bridge session cannot preserve exact file-dialog execution; no input was sent.",
                hint: "Update and relaunch the selected runtime host before retrying.")
        }
    }
}
