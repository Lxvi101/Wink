import Foundation
import WinkAutomationKit
import WinkFoundation
import Testing
@testable import WinkBridge

struct ExactFileDialogWireTests {
    @Test
    func `typed file payload round trips the full selector and focus policy`() throws {
        let execution = try DialogFileExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242, windowID: 700),
            path: "/tmp/fixture",
            filename: "receipt.txt",
            actionButton: "Save",
            ensureExpanded: true,
            focus: DialogForegroundFocusPolicy(
                autoFocus: false,
                timeout: 2.5,
                retryCount: 4,
                switchSpace: true,
                bringToCurrentSpace: false))
        let wire = WinkBridgeRequest.dialogHandleFile(.init(execution: execution))
        let data = try JSONEncoder.winkBridgeEncoder().encode(wire)
        let decoded = try JSONDecoder.winkBridgeDecoder().decode(WinkBridgeRequest.self, from: data)

        guard case let .dialogHandleFile(payload) = decoded else {
            Issue.record("Expected the existing dialogHandleFile operation with a typed body")
            return
        }
        #expect(payload.execution == execution)
        #expect(payload.path == nil)
        #expect(payload.appName == nil)
        #expect(decoded.requiresExactFileDialogExecution)
        #expect(decoded.minimumNegotiatedProtocolVersion == WinkBridgeConstants.exactFileDialogExecutionVersion)
        #expect(WinkBridgeConstants.exactFileDialogExecutionVersion == .init(major: 1, minor: 43))
        #expect(WinkBridgeHostCapability.exactFileDialogExecution == "exactFileDialogExecution")
    }

    @Test
    func `legacy file payload keeps its original wire shape`() throws {
        let data = Data(#"{"path":"/tmp","filename":"old.txt","ensureExpanded":true,"appName":"Fixture"}"#.utf8)
        let decoded = try JSONDecoder.winkBridgeDecoder().decode(
            WinkBridgeDialogHandleFileRequest.self, from: data)
        #expect(decoded.execution == nil)
        #expect(decoded.path == "/tmp")
        #expect(decoded.filename == "old.txt")
        #expect(decoded.ensureExpanded == true)
        #expect(decoded.appName == "Fixture")
        let encoded = try JSONEncoder.winkBridgeEncoder().encode(decoded)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["execution"] == nil)
        #expect(Set(object.keys) == ["path", "filename", "ensureExpanded", "appName"])
        #expect(!WinkBridgeRequest.dialogHandleFile(decoded).requiresExactFileDialogExecution)
    }

    @Test
    func `typed file payload rejects null execution and mixed legacy keys`() throws {
        let execution = try DialogFileExecutionRequest(target: DialogTargetSelector(windowID: 700))
        let data = try JSONEncoder.winkBridgeEncoder().encode(
            WinkBridgeDialogHandleFileRequest(execution: execution))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for legacyKey in ["path", "filename", "actionButton", "ensureExpanded", "appName"] {
            var mixed = object
            mixed[legacyKey] = NSNull()
            let mixedData = try JSONSerialization.data(withJSONObject: mixed)
            #expect(throws: (any Error).self) {
                try JSONDecoder.winkBridgeDecoder().decode(
                    WinkBridgeDialogHandleFileRequest.self, from: mixedData)
            }
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder.winkBridgeDecoder().decode(
                WinkBridgeDialogHandleFileRequest.self, from: Data(#"{"execution":null}"#.utf8))
        }
    }

    @Test
    func `typed file success semantics are exact foreground and counted without enabling legacy success`() throws {
        let execution = try DialogFileExecutionRequest(target: DialogTargetSelector(windowID: 700))
        let typed = WinkBridgeOperationResultSemantics.semanticPlan(
            for: .dialogHandleFile(.init(execution: execution)))
        let legacy = WinkBridgeOperationResultSemantics.semanticPlan(
            for: .dialogHandleFile(.init(
                path: nil, filename: nil, actionButton: nil, ensureExpanded: nil, appName: nil)))

        #expect(typed.contract.targetPolicy == .responseResolved)
        #expect(typed.successResponsePolicy == .ordinary)
        #expect(typed.allowedSuccessStates == [.confirmedChange, .dispatchedUnverified])
        #expect(legacy.successResponsePolicy == .errorOnly)
        #expect(typed.successfulDeliveryRules.count == 6)
        for rule in typed.successfulDeliveryRules {
            #expect(rule.delivery.mode == .foreground)
            #expect(rule.units == .positive)
            #expect(!rule.units.acceptsSuccessful(nil))
            #expect(rule.units.acceptsSuccessful(.init(3)))
        }
        #expect(typed.deliveryRule(for: .init(mechanism: .accessibilityValue, mode: .background)) == nil)
    }
}
