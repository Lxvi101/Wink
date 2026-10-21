import Foundation
import WinkAutomationKit
import Testing
@testable import WinkBridge

struct WinkBridgeTextSelectionTests {
    @Test(arguments: TextSelectionType.allCases)
    func `typed selection request and result round trip and bind`(mode: TextSelectionType) throws {
        let selection = TextSelectionRequest(text: "🦞", prefix: "a", suffix: "b", selectionType: mode)
        let request = WinkBridgeRequest.selectText(.init(target: "T1", request: selection, snapshotId: "snapshot"))
        let decodedRequest = try JSONDecoder.winkBridgeDecoder().decode(
            WinkBridgeRequest.self, from: JSONEncoder.winkBridgeEncoder().encode(request))
        #expect(decodedRequest.operation == .selectText)
        let response = try WinkBridgeResponse.elementActionResult(.init(
            target: "T1",
            actionName: "AXSelectedTextRange",
            anchorPoint: nil,
            textSelection: selection.resolve(in: "a🦞b")))
        let decodedResponse = try JSONDecoder.winkBridgeDecoder().decode(
            WinkBridgeResponse.self, from: JSONEncoder.winkBridgeEncoder().encode(response))
        let plan = WinkBridgeOperationResultSemantics.requestPlan(for: decodedRequest, vocabulary: .current)
        try plan.validateBoundTypedResponse(decodedResponse, outcome: nil)
        let projected = try decodedResponse.projectingSetValueVerification(offered: false, request: request)
        try plan.validateBoundTypedResponse(projected, outcome: nil)
    }

    @Test
    func `old protocols cannot advertise selection`() {
        #expect(!WinkBridgeOperation.compatible([.selectText], with: .init(major: 1, minor: 41))
            .contains(.selectText))
        #expect(WinkBridgeOperation.compatible([.selectText], with: .init(major: 1, minor: 42))
            .contains(.selectText))
    }

    @Test
    func `wrong target wrong mode missing evidence and value writes fail result binding`() throws {
        let request = TextSelectionRequest(text: "needle", selectionType: .cursorAfter)
        let wire = WinkBridgeRequest.selectText(.init(target: "T1", request: request, snapshotId: "snapshot"))
        let plan = WinkBridgeOperationResultSemantics.requestPlan(for: wire, vocabulary: .current)
        let range = try #require(TextSelectionRange(location: 3, length: 6))
        let correct = TextSelectionResult(matchedRange: range, selectionType: .cursorAfter)
        let results: [ElementActionResult] = [
            .init(target: "T2", actionName: "AXSelectedTextRange", anchorPoint: nil, textSelection: correct),
            .init(target: "T1", actionName: "AXSelectedTextRange", anchorPoint: nil),
            .init(target: "T1", actionName: "AXSetValue", anchorPoint: nil, textSelection: correct),
            .init(
                target: "T1",
                actionName: "AXSelectedTextRange",
                anchorPoint: nil,
                newValue: "changed",
                textSelection: correct),
            .init(
                target: "T1",
                actionName: "AXSelectedTextRange",
                anchorPoint: nil,
                textSelection: .init(matchedRange: range, selectionType: .text)),
        ]
        for result in results {
            #expect(throws: WinkBridgeOperationReceiptError.self) {
                try plan.validateBoundTypedResponse(.elementActionResult(result), outcome: nil)
            }
        }
    }
}
