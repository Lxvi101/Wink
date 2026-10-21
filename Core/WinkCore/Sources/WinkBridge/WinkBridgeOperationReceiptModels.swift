import CoreGraphics
import CryptoKit
import Foundation
import WinkAutomationKit
import WinkFoundation

public struct WinkBridgeAttestedOperationRequest: Codable, Sendable {
    public let requestID: UUID
    public let sessionID: UUID
    public let sessionSequence: WinkBridgeOperationSessionSequence
    public let expectedListenerInstanceID: UUID
    public let clientInstanceID: UUID
    public let client: WinkBridgeOperationProcessIdentity
    public let request: WinkBridgeRequest

    public init(
        requestID: UUID,
        sessionID: UUID,
        sessionSequence: WinkBridgeOperationSessionSequence,
        expectedListenerInstanceID: UUID,
        clientInstanceID: UUID,
        client: WinkBridgeOperationProcessIdentity,
        request: WinkBridgeRequest)
    {
        self.requestID = requestID
        self.sessionID = sessionID
        self.sessionSequence = sessionSequence
        self.expectedListenerInstanceID = expectedListenerInstanceID
        self.clientInstanceID = clientInstanceID
        self.client = client
        self.request = request
    }

    private enum CodingKeys: String, CodingKey {
        case requestID
        case sessionID
        case sessionSequence
        case expectedListenerInstanceID
        case clientInstanceID
        case client
        case request
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestID = try container.decode(UUID.self, forKey: .requestID)
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.sessionSequence = try container.decode(
            WinkBridgeOperationSessionSequence.self,
            forKey: .sessionSequence)
        self.expectedListenerInstanceID = try container.decode(UUID.self, forKey: .expectedListenerInstanceID)
        self.clientInstanceID = try container.decode(UUID.self, forKey: .clientInstanceID)
        self.client = try container.decode(WinkBridgeOperationProcessIdentity.self, forKey: .client)
        self.request = try container.decode(WinkBridgeRequestCodingBox.self, forKey: .request).value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.requestID, forKey: .requestID)
        try container.encode(self.sessionID, forKey: .sessionID)
        try container.encode(self.sessionSequence, forKey: .sessionSequence)
        try container.encode(self.expectedListenerInstanceID, forKey: .expectedListenerInstanceID)
        try container.encode(self.clientInstanceID, forKey: .clientInstanceID)
        try container.encode(self.client, forKey: .client)
        try container.encode(WinkBridgeRequestCodingBox(self.request), forKey: .request)
    }

    func validateEnvelope() throws {
        guard self.requestID == WinkBridgeOperationReceiptCoding.deterministicRequestID(
            sessionID: self.sessionID,
            sequence: self.sessionSequence)
        else {
            throw WinkBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Attested Bridge operation request ID does not match its session sequence")
        }
    }

    func validatedRequest() throws -> WinkBridgeRequest {
        try self.validateEnvelope()
        try self.request.validateAttestedOperationCarriage()
        return self.request
    }
}

extension WinkBridgeOperationReceiptSemantics {
    static func validateTargetAttribution(
        _ payload: WinkBridgeOperationReceiptPayload,
        request: WinkBridgeRequest,
        response: WinkBridgeResponse) throws
    {
        try self.validateTargetAttribution(
            payload,
            plan: WinkBridgeOperationResultSemantics.semanticPlan(for: request),
            response: response)
    }

    static func validateReceiptCarriage(
        _ payload: WinkBridgeOperationReceiptPayload,
        request: WinkBridgeRequest,
        response: WinkBridgeResponse) throws
    {
        try self.validateReceiptCarriage(
            payload,
            plan: WinkBridgeOperationResultSemantics.semanticPlan(for: request),
            response: response)
    }
}

extension WinkBridgeRequest {
    fileprivate func validateAttestedOperationCarriage() throws {
        try self.validateAttestedOperationCarriage(
            plan: WinkBridgeOperationResultSemantics.semanticPlan(for: self))
    }

    fileprivate func validateAttestedOperationCarriage(
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan) throws
    {
        switch self {
        case .attestedOperation:
            throw WinkBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Attested Bridge operation requests cannot be nested")
        case .handshake:
            throw WinkBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Bridge handshakes cannot use operation receipt carriage")
        case let .projectedAction(payload):
            let nested = try payload.validatedRequest()
            if case .attestedOperation = nested {
                throw WinkBridgeErrorEnvelope(
                    code: .invalidRequest,
                    message: "Attested Bridge operation requests cannot be nested inside action carriage")
            }
        case _ where plan.result.completion.mutatesDesktop:
            throw WinkBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Mutating attested Bridge operations require action outcome carriage")
        default:
            break
        }
    }
}

public struct WinkBridgeOperationReceiptBundle: Codable, Equatable, Sendable {
    public let operationAttestation: WinkBridgeListenerAttestation
    public let operationSessionAttestation: WinkBridgeOperationSessionAttestation
    public let receipt: WinkBridgeOperationReceipt
    public let canonicalListenerAttestationPayload: Data
    public let canonicalSessionAttestationPayload: Data
    public let canonicalReceiptPayload: Data
    public let canonicalRequest: Data
    public let canonicalResponse: Data

    public init(
        operationAttestation: WinkBridgeListenerAttestation,
        operationSessionAttestation: WinkBridgeOperationSessionAttestation,
        receipt: WinkBridgeOperationReceipt,
        canonicalListenerAttestationPayload: Data,
        canonicalSessionAttestationPayload: Data,
        canonicalReceiptPayload: Data,
        canonicalRequest: Data,
        canonicalResponse: Data)
    {
        self.operationAttestation = operationAttestation
        self.operationSessionAttestation = operationSessionAttestation
        self.receipt = receipt
        self.canonicalListenerAttestationPayload = canonicalListenerAttestationPayload
        self.canonicalSessionAttestationPayload = canonicalSessionAttestationPayload
        self.canonicalReceiptPayload = canonicalReceiptPayload
        self.canonicalRequest = canonicalRequest
        self.canonicalResponse = canonicalResponse
    }

    /// Validates canonical encoding, signatures, request/response semantics, and target attribution.
    ///
    /// The listener attestation is carried by the bundle and self-signed, so this compatibility API
    /// proves internal integrity only. Certification must call ``validate(trustAnchor:)`` with an
    /// independently authenticated listener anchor.
    public func validate() throws {
        try self.validateIntegrity()
    }

    public func validate(trustAnchor: WinkBridgeOperationReceiptTrustAnchor) throws {
        let matches = switch trustAnchor {
        case let .listenerAttestation(expected):
            self.operationAttestation == expected
        case let .listenerPublicKey(expected):
            self.operationAttestation.publicKey == expected
        case let .listenerPublicKeySHA256(expected):
            WinkBridgeOperationReceiptCoding.sha256(self.operationAttestation.publicKey) == expected
        case let .listenerAttestationSHA256(expected):
            try WinkBridgeOperationReceiptCoding.sha256(self.operationAttestation) == expected
        }
        guard matches else {
            throw WinkBridgeOperationReceiptError.receiptMismatch(
                "the independently trusted listener anchor")
        }
        try self.validateIntegrity()
    }

    public func validateIntegrity() throws {
        guard try self.canonicalListenerAttestationPayload == (WinkBridgeOperationReceiptCoding.canonicalData(
            self.operationAttestation.unsignedPayload)),
            try self.canonicalSessionAttestationPayload == (WinkBridgeOperationReceiptCoding.canonicalData(
                self.operationSessionAttestation.unsignedPayload)),
            try self.canonicalReceiptPayload == (WinkBridgeOperationReceiptCoding.canonicalData(
                self.receipt.payload))
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("the exported signature payload bytes")
        }
        try self.operationAttestation.validateSignature()
        try self.operationSessionAttestation.validateSignature(listenerAttestation: self.operationAttestation)
        try self.receipt.validateSignature(publicKey: self.operationAttestation.publicKey)
        let request: WinkBridgeRequest
        let response: WinkBridgeResponse
        do {
            request = try JSONDecoder.winkBridgeDecoder().decode(
                WinkBridgeRequest.self,
                from: self.canonicalRequest)
            response = try JSONDecoder.winkBridgeDecoder().decode(
                WinkBridgeResponse.self,
                from: self.canonicalResponse)
            if case .projectedAction = request {
                // Invalid projected carriage can have one canonical signed refusal, validated below.
            } else {
                try request.validateAttestedOperationCarriage()
            }
        } catch {
            throw WinkBridgeOperationReceiptError.receiptMismatch("the exported request or response bytes")
        }
        let payload = self.receipt.payload
        guard try self.canonicalRequest == WinkBridgeOperationReceiptCoding.canonicalData(request),
              try self.canonicalResponse == WinkBridgeOperationReceiptCoding.canonicalData(response),
              payload.schemaVersion == 1,
              payload.requestID == WinkBridgeOperationReceiptCoding.deterministicRequestID(
                  sessionID: payload.sessionID,
                  sequence: payload.sessionSequence),
              payload.sessionID == self.operationSessionAttestation.sessionID,
              payload.sessionSequence.value < UInt64(self.operationSessionAttestation.maximumRequestCount),
              try payload.sessionAttestationSHA256 == WinkBridgeOperationReceiptCoding.sha256(
                  self.operationSessionAttestation),
              payload.listenerInstanceID == self.operationAttestation.listenerInstanceID,
              self.receipt.payload.listenerPublicKeySHA256 == WinkBridgeOperationReceiptCoding.sha256(
                  self.operationAttestation.publicKey),
              payload.host == self.operationAttestation.host,
              payload.clientInstanceID == self.operationSessionAttestation.clientInstanceID,
              payload.client == self.operationSessionAttestation.client,
              payload.client.processIdentifier > 0,
              payload.client.processStartIdentity > 0,
              !payload.client.codeSignatureHash.isEmpty,
              payload.operation == request.operation,
              payload.requestSHA256 == WinkBridgeOperationReceiptCoding.sha256(
                  self.canonicalRequest),
              payload.responseSHA256 == WinkBridgeOperationReceiptCoding.sha256(self.canonicalResponse),
              payload.outcome == WinkBridgeOperationReceiptSemantics.outcome(in: response),
              payload.remainingClaimCount >= 0,
              payload.remainingClaimCount < self.operationSessionAttestation.maximumRequestCount,
              payload.startedAtUnixMilliseconds > 0,
              payload.completedAtUnixMilliseconds >= payload.startedAtUnixMilliseconds
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("the exported verification bundle")
        }
        try WinkBridgeOperationReceiptSemantics.validateTargetAttribution(
            payload,
            request: request,
            response: response)
        if case let .certificationProducerAttestation(certificationRequest) = request,
           case let .certificationProducerAttestation(certificationResponse) = response
        {
            try certificationResponse.validate(
                request: certificationRequest,
                listenerAttestation: self.operationAttestation)
        }
    }

    /// Exact deterministic bytes accepted by `bridge receipt validate` and offline verifiers.
    public func canonicalEncodedData() throws -> Data {
        try WinkBridgeOperationReceiptCoding.canonicalData(self)
    }
}

enum WinkBridgeOperationReceiptSemantics {
    private struct ExpectedSelectedLeaf {
        let kind: DesktopSelectedLeafEvidence.Kind
        let selector: String
        let index: Int?
        let resolvedLeaf: DesktopSelectedLeafEvidence?
        let requiresResolvedLeaf: Bool
    }

    static func outcome(in response: WinkBridgeResponse) -> DesktopActionOutcome.Projection? {
        switch response {
        case let .projectedAction(payload): payload.outcome
        case let .error(envelope): envelope.actionOutcome
        default: nil
        }
    }

    static func allowsTargetlessFailureReceipt(for response: WinkBridgeResponse) -> Bool {
        WinkBridgeOperationResultSemantics.isNoDispatchFailure(response) &&
            WinkBridgeOperationReceiptPayload.isCanonicalTargetlessFailureOutcome(self.outcome(in: response))
    }

    static func validateTargetAttribution(
        _ payload: WinkBridgeOperationReceiptPayload,
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan,
        response: WinkBridgeResponse) throws
    {
        try payload.validateTargetState()
        try self.validateReceiptCarriage(payload, plan: plan, response: response)
        guard let failure = payload.targetAttributionFailure else {
            if self.errorEnvelope(in: response)?.context?.hasPrefix("bridge_target_attribution:") == true {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "target attribution success response context")
            }
            try self.validateSuccessfulTargetAttribution(
                payload,
                plan: plan,
                response: response)
            return
        }
        try self.validateFailedTargetAttribution(
            payload,
            failure: failure,
            plan: plan,
            response: response)
    }

    static func validateReceiptCarriage(
        _ payload: WinkBridgeOperationReceiptPayload,
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan,
        response: WinkBridgeResponse) throws
    {
        let request = plan.carriageRequest
        do {
            try request.validateAttestedOperationCarriage(plan: plan)
        } catch {
            try self.validateInvalidRequestCarriageRefusal(
                payload,
                request: request,
                response: response)
            return
        }
        let semanticResponse: WinkBridgeResponse = if case let .projectedAction(projected) = response {
            projected.response
        } else {
            response
        }
        guard WinkBridgeOperationResultSemantics.responseMatchesContract(
            semanticResponse,
            plan: plan)
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("operation response family")
        }
        if plan.result.completion.mutatesDesktop {
            guard case .projectedAction = request,
                  case let .projectedAction(projected) = response,
                  let outcome = projected.outcome,
                  outcome.route == .bridge,
                  payload.outcome == outcome
            else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("mutating action outcome carriage")
            }
        } else {
            if case .projectedAction = response, case .projectedAction = request {
                // Read-only application checks opt into action carriage so a canonical refusal is not erased.
            } else if case .projectedAction = response {
                throw WinkBridgeOperationReceiptError.receiptMismatch("read-only projected response carriage")
            }
            let readOnlyOutcome = self.outcome(in: response)
            guard payload.outcome == readOnlyOutcome else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("read-only action outcome carriage")
            }
            if let outcome = readOnlyOutcome?.outcome {
                guard case .error = semanticResponse,
                      outcome.route == .bridge,
                      !outcome.isConfirmed,
                      WinkBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                          outcome,
                          plan: plan)
                else {
                    throw WinkBridgeOperationReceiptError.receiptMismatch(
                        "read-only action outcome semantics")
                }
            }
        }
        if request.operation == .agentExecutionTrace {
            if case .error = semanticResponse {
                // Signed pre-release refusals have no spawned-process response to bind.
            } else {
                guard case let .agentExecutionTrace(result) = semanticResponse,
                      result.requestingPeer == payload.client
                else {
                    throw WinkBridgeOperationReceiptError.receiptMismatch(
                        "Agent execution authenticated requesting peer")
                }
            }
        }
        try self.validateTypedResponseSemantics(semanticResponse, outerResponse: response, plan: plan)
        try self.validateResponseOutcomeConsistency(response, plan: plan)
        try self.validateSelectedLeafEvidence(payload, request: request, response: semanticResponse)
    }

    private static func validateInvalidRequestCarriageRefusal(
        _ payload: WinkBridgeOperationReceiptPayload,
        request: WinkBridgeRequest,
        response: WinkBridgeResponse) throws
    {
        guard case .projectedAction = request,
              case let .projectedAction(projected) = response,
              case let .error(envelope) = projected.response,
              envelope.code == .invalidRequest,
              let outcome = envelope.actionOutcome?.outcome,
              projected.outcome == envelope.actionOutcome,
              payload.outcome == projected.outcome,
              payload.target == nil,
              payload.targetAttributionFailure == nil,
              payload.targetAttributionEvidence == nil,
              payload.focusedElement == nil,
              payload.selectedLeafEvidence == nil,
              outcome.route == .bridge,
              outcome.state == .refused,
              outcome.effect == .refused,
              outcome.delivery == nil,
              outcome.evidence == .requestRefused,
              outcome.dispatchState == .none,
              outcome.retrySafety == .safe,
              outcome.refusalReason == .invalidRequest
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("attested request carriage")
        }
    }

    private static func validateSelectedLeafEvidence(
        _ payload: WinkBridgeOperationReceiptPayload,
        request: WinkBridgeRequest,
        response: WinkBridgeResponse) throws
    {
        let request = request.unwrappedOperationRequest
        let errorEnvelope: WinkBridgeErrorEnvelope? = if case let .error(envelope) = response {
            envelope
        } else {
            nil
        }
        if let errorEnvelope,
           errorEnvelope.actionOutcome?.mutationDispatched != true
        {
            guard payload.selectedLeafEvidence == nil else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "no-dispatch failure selected-leaf evidence")
            }
            return
        }

        try self.validateScopedMenuBarSelectedLeaf(request)
        let expected: [ExpectedSelectedLeaf]? = switch request {
        case let .clickMenuExtra(value):
            [.init(
                kind: .menuBarItem,
                selector: DeterministicDesktopLeafSelector.normalized(value.name),
                index: nil,
                resolvedLeaf: nil,
                requiresResolvedLeaf: false)]
        case let .clickMenuBarItemNamed(value):
            [.init(
                kind: .menuBarItem,
                selector: DeterministicDesktopLeafSelector.normalized(value.name),
                index: nil,
                resolvedLeaf: value.expectedLeafEvidence,
                requiresResolvedLeaf: true)]
        case let .clickMenuBarItemIndex(value):
            [.init(
                kind: .menuBarItem,
                selector: String(value.index),
                index: value.index,
                resolvedLeaf: value.expectedLeafEvidence,
                requiresResolvedLeaf: true)]
        case let .launchDockItem(value):
            [.init(
                kind: .dockItem,
                selector: DeterministicDesktopLeafSelector.normalized(value.appName),
                index: nil,
                resolvedLeaf: nil,
                requiresResolvedLeaf: false)]
        case let .rightClickDockItem(value):
            if let menuItem = value.menuItem {
                [
                    .init(
                        kind: .dockItem,
                        selector: DeterministicDesktopLeafSelector.normalized(value.appName),
                        index: nil,
                        resolvedLeaf: nil,
                        requiresResolvedLeaf: false),
                    .init(
                        kind: .dockContextMenuItem,
                        selector: DeterministicDesktopLeafSelector.normalized(menuItem),
                        index: nil,
                        resolvedLeaf: nil,
                        requiresResolvedLeaf: false),
                ]
            } else {
                [.init(
                    kind: .dockItem,
                    selector: DeterministicDesktopLeafSelector.normalized(value.appName),
                    index: nil,
                    resolvedLeaf: nil,
                    requiresResolvedLeaf: false)]
            }
        case let .desktopObservation(value):
            self.desktopObservationSelectedLeafExpectation(
                value,
                outcome: payload.outcome?.outcome)
        default:
            nil
        }
        guard let expected else {
            guard payload.selectedLeafEvidence == nil else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "unexpected selected-leaf evidence")
            }
            return
        }
        let boundExpected: [ExpectedSelectedLeaf]
        if errorEnvelope != nil {
            guard let dispatchedCount = payload.outcome?.dispatchedUnitCount?.rawValue,
                  dispatchedCount > 0
            else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "failed selected-leaf dispatch count")
            }
            boundExpected = Array(expected.prefix(min(dispatchedCount, expected.count)))
        } else {
            boundExpected = expected
        }
        guard let evidence = payload.selectedLeafEvidence,
              evidence.count == boundExpected.count,
              !evidence.isEmpty
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("selected-leaf evidence carriage")
        }
        if let errorEnvelope,
           errorEnvelope.actionSelectedLeafEvidence != evidence
        {
            throw WinkBridgeOperationReceiptError.receiptMismatch(
                "failure selected-leaf response carriage")
        }
        for (actual, expected) in zip(evidence, boundExpected) {
            guard self.selectedLeaf(actual, matches: expected) else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("selected-leaf request binding")
            }
        }
        try self.validateSelectedLeafTarget(evidence, receiptTarget: payload.target)
    }

    private static func validateScopedMenuBarSelectedLeaf(_ request: WinkBridgeRequest) throws {
        guard case let .clickMenuBarItemNamed(value) = request, let scope = value.applicationScope else { return }
        guard let leaf = value.expectedLeafEvidence,
              leaf.selectedTargetReceipt.windowID == nil,
              scope.explicitProcessIdentifier.map({ $0 == leaf.selectedTargetReceipt.processIdentifier }) ?? true
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("menu bar application scope")
        }
    }

    private static func desktopObservationSelectedLeafExpectation(
        _ request: DesktopObservationRequest,
        outcome: DesktopActionOutcome?) -> [ExpectedSelectedLeaf]?
    {
        guard case let .menubarPopover(hints, openIfNeeded) = request.target,
              let openIfNeeded
        else { return nil }
        let setupDelivery = DesktopActionOutcome.Delivery(
            mechanism: .windowTargetedEvents,
            mode: .background)
        guard outcome?.delivery == setupDelivery else { return nil }
        let selector = ([openIfNeeded.clickHint] + hints.map(Optional.some))
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let selector else { return [] }
        return [.init(
            kind: .menuBarItem,
            selector: DeterministicDesktopLeafSelector.normalized(selector),
            index: nil,
            resolvedLeaf: nil,
            requiresResolvedLeaf: false)]
    }

    private static func selectedLeaf(
        _ actual: DesktopSelectedLeafEvidence,
        matches expected: ExpectedSelectedLeaf) -> Bool
    {
        guard actual.isCanonical,
              actual.kind == expected.kind,
              actual.normalizedSelector == expected.selector,
              actual.winningCandidateCount == 1,
              !actual.hasWinningTie,
              expected.index.map({ actual.matchKind == .index && actual.selectedIndex == $0 }) ??
              (actual.matchKind != .index)
        else {
            return false
        }
        guard expected.requiresResolvedLeaf else { return expected.resolvedLeaf == nil }
        guard let expectedLeaf = expected.resolvedLeaf,
              expectedLeaf.isCanonical,
              expectedLeaf.kind == expected.kind,
              expectedLeaf.normalizedSelector == expected.selector,
              expectedLeaf.winningCandidateCount == 1,
              !expectedLeaf.hasWinningTie,
              expected.index.map({ expectedLeaf.matchKind == .index && expectedLeaf.selectedIndex == $0 }) ??
              (expectedLeaf.matchKind != .index)
        else {
            return false
        }
        return actual.hasSameResolvedLeaf(as: expectedLeaf)
    }

    private static func validateSelectedLeafTarget(
        _ evidence: [DesktopSelectedLeafEvidence],
        receiptTarget: WinkBridgeOperationTargetReceipt?) throws
    {
        let expectedProcess: ApplicationProcessIdentity
        let expectedWindow: WindowMutationIdentity?
        switch receiptTarget {
        case let .process(process):
            expectedProcess = process
            expectedWindow = nil
        case let .window(window):
            expectedProcess = window.processIdentity
            expectedWindow = window
        case .global, .browser, nil:
            throw WinkBridgeOperationReceiptError.receiptMismatch("selected-leaf target attribution")
        }
        guard evidence.allSatisfy({ $0.selectedProcessIdentity == expectedProcess }),
              expectedWindow.map({ evidence.first?.selects(window: $0) == true }) ?? true
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("selected-leaf target identity")
        }
    }

    private static func validateSuccessfulTargetAttribution(
        _ payload: WinkBridgeOperationReceiptPayload,
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan,
        response: WinkBridgeResponse) throws
    {
        let request = plan.carriageRequest
        if self.allowsTargetlessFailureReceipt(for: response) {
            guard payload.target == nil else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("no-dispatch failure target")
            }
            return
        }
        guard payload.target != nil else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("targetless successful attribution")
        }
        do {
            _ = try WinkBridgeOperationTargetAttribution.resolveRequest(plan)
        } catch {
            throw WinkBridgeOperationReceiptError.receiptMismatch(
                "successful request target contract")
        }
        if [.browserConnect, .browserExecute].contains(request.operation),
           plan.result.completion.mutatesDesktop,
           !WinkBridgeOperationResultSemantics.isNoDispatchFailure(response)
        {
            guard let responseReceipt = response.browserExecutionConnectionReceipt,
                  responseReceipt.isCanonicalTarget
            else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "browser connection target attribution")
            }
            if request.operation == .browserConnect {
                guard let connectRequest = request.browserConnectRequest,
                      responseReceipt.matchesConnectRequest(connectRequest)
                else {
                    throw WinkBridgeOperationReceiptError.receiptMismatch(
                        "browser connection request attribution")
                }
            } else if request.operation == .browserExecute {
                if let requestedChannel = request.browserRequestedChannel,
                   responseReceipt.channel != requestedChannel
                {
                    throw WinkBridgeOperationReceiptError.receiptMismatch(
                        "browser connection channel attribution")
                }
                guard let expectedReceipt = request.browserExecutionRequest?.expectedConnectionReceipt else {
                    throw WinkBridgeOperationReceiptError.receiptMismatch(
                        "browser request connection attribution")
                }
                guard responseReceipt == expectedReceipt else {
                    throw WinkBridgeOperationReceiptError.receiptMismatch(
                        "browser connection request attribution")
                }
            }
            if responseReceipt.isCanonicalExternalTarget {
                guard payload.target == .browser(responseReceipt),
                      payload.focusedElement == nil
                else {
                    throw WinkBridgeOperationReceiptError.receiptMismatch(
                        "external browser connection target attribution")
                }
                return
            }
        }
        if case .browser = payload.target,
           ![WinkBridgeOperation.browserConnect, .browserExecute].contains(request.operation)
        {
            throw WinkBridgeOperationReceiptError.receiptMismatch(
                "browser target used outside external browser execution")
        }
        let signedIdentity = try payload.resolvedTargetIdentity()
        let targetPolicy = plan.target.policy
        let handledTarget: DesktopTargetIdentity? = switch targetPolicy {
        case .handlerRequired, .handlerResolvedOrGlobal, .external:
            signedIdentity
        case .responseResolved:
            self.errorEnvelope(in: response)?.actionTargetReceipt == nil ? nil : signedIdentity
        case .notApplicable, .requestDependent, .global, .requestPinned:
            nil
        }
        let resolvedIdentity: DesktopTargetIdentity?
        do {
            resolvedIdentity = try WinkBridgeOperationTargetAttribution.resolve(
                plan: plan,
                response: response,
                handledTarget: handledTarget)
        } catch {
            throw WinkBridgeOperationReceiptError.receiptMismatch(
                "canonical target attribution evidence")
        }
        let resolvedTarget = WinkBridgeResolvedOperationTarget(resolvedIdentity)
        guard payload.target == resolvedTarget.target,
              payload.focusedElement == resolvedTarget.focusedElement
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch(
                "canonical target attribution")
        }
    }

    private static func validateFailedTargetAttribution(
        _ payload: WinkBridgeOperationReceiptPayload,
        failure: WinkBridgeTargetAttributionFailure,
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan,
        response: WinkBridgeResponse) throws
    {
        let request = plan.carriageRequest
        let envelope = self.errorEnvelope(in: response)
        guard envelope?.context == "bridge_target_attribution:\(failure.code.rawValue)" else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("target attribution failure response")
        }
        guard let envelope else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("target attribution error envelope")
        }
        try self.validateFailureResponseSemantics(
            failure,
            plan: plan,
            envelope: envelope)
        guard let signedEvidence = payload.targetAttributionEvidence else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("target attribution failure evidence")
        }
        let requestEvidence = request.operationTargetEvidence.map(WinkBridgeOperationTargetEvidence.init)
        guard Array(signedEvidence.prefix(requestEvidence.count)) == requestEvidence else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("target attribution request evidence")
        }
        switch failure.stage {
        case .preDispatch:
            guard signedEvidence == requestEvidence else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("pre-dispatch target evidence")
            }
            do {
                _ = try WinkBridgeOperationTargetAttribution.resolveRequest(plan)
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "claimed pre-dispatch target attribution failure")
            } catch let error as DesktopTargetIdentityError {
                guard WinkBridgeTargetAttributionFailure.Code(error) == failure.code else {
                    throw WinkBridgeOperationReceiptError.receiptMismatch("target attribution failure code")
                }
            }
            return
        case .postExecution:
            do {
                _ = try WinkBridgeOperationTargetAttribution.resolveRequest(plan)
            } catch {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "post-execution request target evidence")
            }
        }
        do {
            _ = try WinkBridgeOperationTargetAttribution.resolveEvidence(
                plan: plan,
                evidence: signedEvidence.map(\.desktopEvidence))
            throw WinkBridgeOperationReceiptError.receiptMismatch(
                "claimed target attribution failure")
        } catch let error as DesktopTargetIdentityError {
            guard WinkBridgeTargetAttributionFailure.Code(error) == failure.code else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("target attribution failure code")
            }
        }
    }

    private static func validateFailureResponseSemantics(
        _ failure: WinkBridgeTargetAttributionFailure,
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan,
        envelope: WinkBridgeErrorEnvelope) throws
    {
        guard plan.result.completion.mutatesDesktop else {
            guard envelope.code == .invalidRequest,
                  envelope.actionOutcome == nil
            else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "read-only target attribution failure semantics")
            }
            return
        }
        guard let outcome = envelope.actionOutcome?.outcome,
              outcome.route == .bridge
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch(
                "mutating target attribution failure outcome")
        }
        if failure.stage == .preDispatch || !outcome.dispatchState.mutationDispatched {
            guard envelope.code == .invalidRequest,
                  outcome.state == .refused,
                  outcome.evidence == .requestRefused,
                  outcome.dispatchState == .none,
                  outcome.retrySafety == .safe,
                  outcome.refusalReason == .invalidRequest
            else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "retry-safe target attribution refusal")
            }
        } else {
            guard envelope.code == .internalError,
                  outcome.state == .indeterminate,
                  outcome.evidence == .completionUnknown,
                  outcome.dispatchState.mutationDispatched,
                  outcome.retrySafety == .unsafe,
                  WinkBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                      outcome,
                      plan: plan)
            else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "retry-unsafe target attribution failure")
            }
        }
    }

    private static func errorEnvelope(in response: WinkBridgeResponse) -> WinkBridgeErrorEnvelope? {
        switch response {
        case let .error(envelope):
            envelope
        case let .projectedAction(projected):
            if case let .error(envelope) = projected.response {
                envelope
            } else {
                nil
            }
        default:
            nil
        }
    }
}

extension WinkBridgeOperationReceiptSemantics {
    private static func validateTypedResponseSemantics(
        _ response: WinkBridgeResponse,
        outerResponse: WinkBridgeResponse,
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan) throws
    {
        let request = plan.request
        let outerOutcome = self.outcome(in: outerResponse)?.outcome
        try plan.validateBoundTypedResponse(response, outcome: outerOutcome)
        if plan.responseCarriesPostMutationWindowState,
           outerOutcome?.isConfirmed == true,
           case .window = response
        {
            // The typed response below proves the requested postcondition.
        } else if plan.responseCarriesPostMutationWindowState,
                  outerOutcome?.isConfirmed == true
        {
            throw WinkBridgeOperationReceiptError.receiptMismatch(
                "confirmed window mutation response proof")
        }
        switch (plan.operationPolicy.typedResponse, request, response) {
        case let (.focusedElement, .getFocusedElement(expected), .focusedElement(focused)):
            guard focused.map({ $0.processId == Int(expected.targetProcessIdentifier) }) ?? true else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("focused-element response process")
            }
        case let (.applicationIdentifier, .findApplication(expected), .application(application)):
            try self.validateApplication(
                application,
                identifier: expected.identifier,
                requireSelectorResolutionProof: true)
        case let (.applicationIdentifier, .launchApplication(expected), .application(application)):
            try self.validateApplication(
                application,
                identifier: expected.identifier,
                requireSelectorResolutionProof: true)
        case let (.applicationLaunch, .launchApplicationWithOptions(expected), .application(application)):
            try self.validateApplication(application, launchRequest: expected)
        case let (.applicationRelaunch, .relaunchApplicationWithOptions(expected), .application(application)):
            try self.validateApplication(application, launchRequest: expected.launchRequest)
            guard let oldIdentity = expected.expectedTargetIdentity,
                  let newIdentity = application.processIdentity,
                  newIdentity != oldIdentity
            else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "relaunch response process generation")
            }
            guard outerOutcome?.state != .confirmedNoChange else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "relaunch response no-change outcome")
            }
        case let (.capture, _, .capture(result)):
            if let mismatch = WinkBridgeCaptureBinding.mismatch(
                request: request,
                result: result,
                requireSelectorResolutionProof: true)
            {
                throw WinkBridgeOperationReceiptError.receiptMismatch("capture \(mismatch)")
            }
        case let (.elementDetection, .detectElements(expected), .elementDetection(actual)):
            try self.validateElementDetection(
                actual,
                expectedSnapshotID: expected.snapshotId,
                expectedWindowContext: expected.windowContext,
                requiresSnapshotBinding: true,
                allowsResolvedWindowContext: false)
        case let (.elementDetection, .inspectAccessibilityTree(expected), .elementDetection(actual)):
            try self.validateElementDetection(
                actual,
                expectedSnapshotID: nil,
                expectedWindowContext: expected.windowContext,
                requiresSnapshotBinding: false,
                allowsResolvedWindowContext: true)
        case let (.desktopObservation, .desktopObservation(expected), .desktopObservation(actual)):
            if let mismatch = WinkBridgeDesktopObservationBinding.mismatch(
                request: expected,
                result: actual,
                requireSelectorResolutionProof: true)
            {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "desktop observation \(mismatch)")
            }
            try self.validateDesktopObservationSetupResult(
                actual,
                request: expected,
                outcome: outerOutcome)
        case let (.postMutationWindow, _, .window(window)):
            try self.validatePostMutationWindow(
                window,
                plan: plan,
                outcome: outerOutcome)
        default:
            try self.validateSelectorResponseSemantics(response, outerResponse: outerResponse, plan: plan)
        }
    }

    private static func validateSelectorResponseSemantics(
        _ response: WinkBridgeResponse,
        outerResponse: WinkBridgeResponse,
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan) throws
    {
        let request = plan.request
        switch (plan.operationPolicy.typedResponse, request, response) {
        case let (.menuStructureApplication, .listMenus(expected), .menuStructure(actual)):
            try self.validateApplication(
                actual.application,
                identifier: expected.appIdentifier,
                requireSelectorResolutionProof: true)
        case let (.waitElementSelector, .waitForElement(expected), .waitResult(actual)):
            try self.validateWaitResult(actual, target: expected.target)
        case let (.dockItemSelector, .findDockItem(expected), .dockItem(actual)):
            guard let actual,
                  self.dockItem(actual, matches: expected.name)
            else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("dock-item response selector")
            }
        case let (.storedDetection, .storeDetectionResult(expected), .ok):
            guard expected.snapshotId == expected.result.snapshotId else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("stored detection snapshot")
            }
        case let (.detectionSnapshot, .getDetectionResult(expected), .detection(actual)):
            guard actual.snapshotId == expected.snapshotId else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("detection response snapshot")
            }
        case let (.snapshotMutationLease, .beginSnapshotMutation(expected), .snapshotMutationLease(actual)):
            guard actual.snapshotId == expected.snapshotId else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("snapshot mutation lease snapshot")
            }
        case let (.dialogResult, _, .dialogResult(result)):
            try self.validateDialogResult(result, outerResponse: outerResponse, request: request)
        case let (.preparedDialogAction, .prepareDialogAction(expected), .preparedDialogAction(receipt)):
            try self.validatePreparedDialogAction(receipt, request: expected)
        case let (.targetedDialogElements, .targetedDialogListElements(selector), .dialogElements(elements)):
            guard let resolved = elements.resolvedTarget else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "targeted dialog list selector evidence")
            }
            try self.validateResolvedDialogTarget(
                resolved,
                exactTarget: resolved.target,
                selector: selector)
        case (.familyOnly, _, _),
             (.noSuccessResponse, _, _),
             (.agentExecutionTrace, _, _),
             (.processGenerationObservation, .observeProcessGeneration, .processGenerationObservation),
             (
                 .certificationProducerAttestation,
                 .certificationProducerAttestation,
                 .certificationProducerAttestation),
             (.typeActions, _, _),
             (.setValue, _, _),
             (.selectText, _, _),
             (.performAction, _, _),
             (.elementDetection, _, _),
             (.postMutationWindow, _, _),
             (.menuStructureApplication, _, _),
             (.waitElementSelector, _, _),
             (.dockItemSelector, _, _),
             (.storedDetection, _, _),
             (.detectionSnapshot, _, _),
             (.snapshotMutationLease, _, _),
             (_, _, .error):
            break
        default:
            throw WinkBridgeOperationReceiptError.receiptMismatch("typed response semantic plan")
        }
    }

    private static func validateApplication(
        _ application: ServiceApplicationInfo,
        launchRequest: ApplicationLaunchRequest) throws
    {
        if let bundleIdentifier = launchRequest.applicationBundleIdentifier {
            guard application.bundleIdentifier == bundleIdentifier else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("application response bundle")
            }
        } else if let identifier = launchRequest.applicationIdentifier {
            try self.validateApplication(
                application,
                identifier: identifier,
                requireSelectorResolutionProof: true)
        }
    }

    private static func validateElementDetection(
        _ result: ElementDetectionResult,
        expectedSnapshotID: String?,
        expectedWindowContext: WindowContext?,
        requiresSnapshotBinding: Bool,
        allowsResolvedWindowContext: Bool) throws
    {
        if requiresSnapshotBinding {
            if let expectedSnapshotID {
                guard result.snapshotId == expectedSnapshotID else {
                    throw WinkBridgeOperationReceiptError.receiptMismatch(
                        "element-detection response snapshot")
                }
            } else if result.snapshotId.isEmpty {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "element-detection generated snapshot")
            }
        }
        if result.metadata.isApplicationScopedAccessibilityFallback {
            try WinkBridgeWindowContextBinding.validateApplicationScopedFallback(
                result.metadata,
                requested: expectedWindowContext,
                allowsResolvedWindowContext: allowsResolvedWindowContext)
            return
        }
        let windowContextMatches = if allowsResolvedWindowContext {
            WinkBridgeWindowContextBinding.refines(
                result.metadata.windowContext,
                requested: expectedWindowContext)
        } else {
            WinkBridgeWindowContextBinding.matches(
                result.metadata.windowContext,
                requested: expectedWindowContext)
        }
        guard windowContextMatches else {
            throw WinkBridgeOperationReceiptError.receiptMismatch(
                "element-detection response window context")
        }
    }

    private static func validateWaitResult(
        _ result: WaitForElementResult,
        target: ClickTarget) throws
    {
        switch target {
        case .coordinates:
            guard result.found, result.element == nil else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("wait response coordinate selector")
            }
        case let .elementId(expectedID):
            guard result.found == (result.element != nil),
                  !result.found || result.element?.id == expectedID
            else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("wait response element selector")
            }
        case let .query(query):
            guard result.found == (result.element != nil),
                  !result.found || result.element.map({ self.element($0, matchesQuery: query) }) == true
            else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("wait response query selector")
            }
        }
    }

    private static func element(_ element: DetectedElement, matchesQuery query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, element.isEnabled, !element.isOCRSemanticEvidence else { return false }
        return [
            element.label,
            element.value,
            element.attributes["identifier"],
            element.attributes["title"],
            element.attributes["description"],
            element.attributes["role"],
        ]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
    }

    private static func dockItem(_ item: DockItem, matches selector: String) -> Bool {
        let selector = selector.lowercased()
        return !selector.isEmpty && item.title.lowercased().contains(selector)
    }

    private static func validateDesktopObservationSetupResult(
        _ result: DesktopObservationResult,
        request: DesktopObservationRequest,
        outcome: DesktopActionOutcome?) throws
    {
        guard case let .menubarPopover(_, openIfNeeded) = request.target,
              openIfNeeded != nil
        else { return }
        let setupDelivery = DesktopActionOutcome.Delivery(
            mechanism: .windowTargetedEvents,
            mode: .background)
        if result.target.mutationTargetIdentity != nil {
            guard outcome?.state == .dispatchedUnverified,
                  outcome?.delivery == setupDelivery,
                  outcome?.dispatchState.unitCount != nil
            else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "menu-bar observation setup outcome")
            }
        } else {
            let pipelineMode: DesktopActionOutcome.Delivery.Mode = request.capture.focus == .background
                ? .background
                : .foreground
            let requiresConditionalPipeline = request.capture.focus != .background ||
                (request.detection.mode != .none && request.detection.allowWebFocusFallback)
            let isNoOp = !requiresConditionalPipeline &&
                outcome?.state == .confirmedNoChange &&
                outcome?.delivery == nil &&
                outcome?.dispatchState == DesktopActionOutcome.DispatchState.none
            let isConditionalPipeline = requiresConditionalPipeline &&
                outcome?.state == .dispatchedUnverified &&
                outcome?.delivery == .init(mechanism: .capturePipeline, mode: pipelineMode) &&
                outcome?.dispatchState.unitCount != nil
            guard isNoOp || isConditionalPipeline else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "menu-bar observation conditional pipeline outcome")
            }
        }
    }

    private static func validateApplication(
        _ application: ServiceApplicationInfo,
        identifier: String,
        requireSelectorResolutionProof: Bool = false) throws
    {
        guard ApplicationIdentifierMatcher.matches(application, identifier: identifier) else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("application response identifier")
        }
        if let mismatch = WinkBridgeSelectorResolutionBinding.applicationMismatch(
            identifier: identifier,
            application: application,
            proofs: application.selectorResolutionProofs,
            requireProof: requireSelectorResolutionProof)
        {
            throw WinkBridgeOperationReceiptError.receiptMismatch(
                "application response selector proof \(mismatch)")
        }
    }

    private static func validatePreparedDialogAction(
        _ receipt: PreparedDialogActionReceipt,
        request: DialogActionPreparationRequest) throws
    {
        if !request.target.hasTarget {
            guard request.kind == .clickButton,
                  receipt.resolvedTarget != nil,
                  receipt.discoveryProof?.validates(target: receipt.target, buttonText: request.buttonText) == true
            else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("automatic dialog discovery proof")
            }
        }
        let identity = receipt.target.identity
        guard receipt.kind == request.kind,
              request.target.processIdentifier.map({ $0 == identity.ownerProcessIdentifier }) ?? true,
              request.target.windowID.map({ $0 == identity.windowID }) ?? true
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("prepared dialog action request")
        }
        try self.validateResolvedDialogTarget(
            receipt.resolvedTarget,
            exactTarget: receipt.target,
            selector: request.target)
    }

    static func validatePostMutationWindow(
        _ window: ServiceWindowInfo?,
        request: WinkBridgeRequest,
        outcome: DesktopActionOutcome?) throws
    {
        try self.validatePostMutationWindow(
            window,
            plan: WinkBridgeOperationResultSemantics.semanticPlan(for: request),
            outcome: outcome)
    }

    static func validatePostMutationWindow(
        _ window: ServiceWindowInfo?,
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan,
        outcome: DesktopActionOutcome?) throws
    {
        let request = plan.request
        guard let expected = plan.pinnedWindowMutation?.identity else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("post-mutation window request target")
        }
        guard let window else {
            guard request.operation == .closeWindow || request.operation == .backgroundCloseWindow else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("post-mutation window response")
            }
            return
        }
        guard window.windowID == expected.windowID,
              let actual = window.mutationIdentity,
              actual.windowID == expected.windowID,
              actual.processIdentity == expected.processIdentity,
              actual.capturedBounds == window.bounds,
              actual.isMinimized.map({ $0 == window.isMinimized }) ?? true
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("post-mutation window identity")
        }
        if [.focusWindow, .minimizeWindow, .restoreWindow].contains(request.operation),
           actual.capturedBounds != expected.capturedBounds
        {
            throw WinkBridgeOperationReceiptError.receiptMismatch(
                "post-mutation window bounds continuity")
        }
        guard outcome?.isConfirmed == true else { return }

        let postconditionSatisfied: Bool = switch request {
        case let .moveWindow(payload):
            window.mutationPostconditionEvidence == nil &&
                WindowMutationGeometryPostcondition.originMatches(
                    window.bounds.origin,
                    payload.position)
        case let .resizeWindow(payload):
            window.mutationPostconditionEvidence == nil &&
                WindowMutationGeometryPostcondition.sizeMatches(
                    window.bounds.size,
                    payload.size)
        case let .setWindowBounds(payload):
            window.mutationPostconditionEvidence == nil &&
                WindowMutationGeometryPostcondition.boundsMatch(
                    window.bounds,
                    payload.bounds)
        case .minimizeWindow:
            window.mutationPostconditionEvidence == nil && window.isMinimized
        case .restoreWindow:
            window.mutationPostconditionEvidence == nil && !window.isMinimized
        case .focusWindow:
            window.mutationPostconditionEvidence == nil &&
                (window.isKeyWindow == true || window.isFrontmost == true)
        case .closeWindow, .backgroundCloseWindow:
            false
        case .maximizeWindow:
            window.mutationPostconditionEvidence?.isMaximized == true &&
                window.mutationPostconditionEvidence?.verifiedVisibleWorkArea.map {
                    WindowMutationGeometryPostcondition.boundsMatch(window.bounds, $0)
                } == true
        default:
            false
        }
        guard postconditionSatisfied else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("post-mutation window postcondition")
        }
    }

    private static func validateDialogResult(
        _ result: DialogActionResult,
        outerResponse: WinkBridgeResponse,
        request: WinkBridgeRequest) throws
    {
        let expectedAction: DialogActionType? = switch request.operation {
        case .dialogClickButton, .backgroundDialogClickButton, .exactDialogClickButton: .clickButton
        case .dialogEnterText, .exactDialogEnterText: .enterText
        case .dialogHandleFile: .handleFileDialog
        case .dialogDismiss, .exactDialogDismiss, .exactDialogForceDismiss: .dismiss
        default: nil
        }
        guard expectedAction == result.action,
              result.success,
              let innerOutcome = result.outcome,
              case let .projectedAction(projected) = outerResponse,
              projected.outcome == innerOutcome.routed(to: .bridge).projection
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("dialog response result semantics")
        }
        switch request {
        case let .exactDialogClickButton(receipt):
            guard receipt.kind == .clickButton else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("exact dialog click request kind")
            }
            do {
                _ = try result.requiredPreparedOutcome(kind: .clickButton)
            } catch {
                throw WinkBridgeOperationReceiptError.receiptMismatch("exact dialog click result")
            }
        case let .exactDialogDismiss(receipt):
            guard receipt.kind == .dismiss else {
                throw WinkBridgeOperationReceiptError.receiptMismatch("exact dialog dismiss request kind")
            }
            do {
                _ = try result.requiredPreparedOutcome(kind: .dismiss)
            } catch {
                throw WinkBridgeOperationReceiptError.receiptMismatch("exact dialog dismiss result")
            }
        case let .exactDialogEnterText(payload):
            try self.validateDialogTargetReceipt(result, selector: payload.target)
        case let .exactDialogForceDismiss(payload):
            try self.validateDialogTargetReceipt(result, selector: payload.target)
        case let .dialogHandleFile(payload):
            if let execution = payload.execution {
                try self.validateDialogTargetReceipt(result, selector: execution.target)
            }
        default:
            break
        }
    }

    private static func validateDialogTargetReceipt(
        _ result: DialogActionResult,
        selector: DialogTargetSelector) throws
    {
        guard let receipt = result.targetReceipt,
              selector.processIdentifier.map({ $0 == receipt.processIdentifier }) ?? true,
              selector.windowID.map({ $0 == receipt.windowID }) ?? true
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("dialog response target receipt")
        }
        let exactTarget: UIAutomationTarget.ExactWindow? = if let identity = result.targetWindowIdentity,
                                                              let bounds = result.targetWindowBounds
        {
            try .init(
                identity: identity,
                bounds: bounds,
                focusedElement: result.focusedElement)
        } else {
            nil
        }
        guard let exactTarget,
              exactTarget.identity.ownerProcessIdentifier == receipt.processIdentifier,
              exactTarget.identity.ownerProcessStartIdentity == receipt.processStartIdentity,
              receipt.windowID.map({ $0 == exactTarget.identity.windowID }) ?? true
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch("dialog response exact target")
        }
        try self.validateResolvedDialogTarget(
            result.resolvedTarget,
            exactTarget: exactTarget,
            selector: selector)
    }

    private static func validateResolvedDialogTarget(
        _ resolved: ResolvedDialogTargetEvidence?,
        exactTarget: UIAutomationTarget.ExactWindow,
        selector: DialogTargetSelector) throws
    {
        let requiresSelectorEvidence = selector.applicationIdentifier != nil ||
            selector.windowTitle != nil || selector.windowIndex != nil
        guard let resolved else {
            guard !requiresSelectorEvidence else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "resolved dialog selector evidence")
            }
            return
        }
        guard resolved.target == exactTarget,
              resolved.matches(selector)
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch(
                "resolved dialog selector evidence")
        }
        if let mismatch = WinkBridgeSelectorResolutionBinding.dialogMismatch(
            selector: selector,
            evidence: resolved,
            requireProof: requiresSelectorEvidence)
        {
            throw WinkBridgeOperationReceiptError.receiptMismatch(
                "resolved dialog selector proof \(mismatch)")
        }
    }

    private static func validateResponseOutcomeConsistency(
        _ response: WinkBridgeResponse,
        plan: WinkBridgeOperationResultSemantics.WinkBridgeRequestPlan) throws
    {
        guard case let .projectedAction(projected) = response else { return }
        if case let .browserToolResponse(browserResponse) = projected.response {
            guard let connectionReceipt = browserResponse.connectionReceipt,
                  connectionReceipt.isCanonicalTarget,
                  let projection = projected.outcome
            else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "browser response progress and outcome")
            }
            if let mismatch = WinkBridgeOperationResultSemantics.browserResponseProgressMismatch(
                browserResponse,
                projection: projection,
                plan: plan)
            {
                throw WinkBridgeOperationReceiptError.receiptMismatch(mismatch.rawValue)
            }
            // Signed completion is stronger than legacy receiptless acceptance of an operation still running.
            if browserResponse.actionFailure == nil, projection.outcome.evidence != .deliveryAccepted {
                throw WinkBridgeOperationReceiptError.receiptMismatch("successful browser response outcome")
            }
            return
        }
        guard let outcome = projected.outcome?.outcome else {
            guard !plan.result.completion.mutatesDesktop else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "projected response outcome")
            }
            if case let .error(envelope) = projected.response,
               envelope.actionOutcome != nil
            {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "read-only projected response outcome")
            }
            return
        }
        if case let .error(envelope) = projected.response {
            guard projected.outcome == envelope.actionOutcome,
                  !outcome.isConfirmed,
                  WinkBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                      outcome,
                      plan: plan)
            else {
                throw WinkBridgeOperationReceiptError.receiptMismatch(
                    "projected error outcome")
            }
            return
        }
        guard WinkBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            outcome,
            response: projected.response,
            plan: plan) || WinkBridgeOperationResultSemantics.nonErrorResponseAllowsFailureOutcome(
            projected.response,
            outcome: outcome,
            plan: plan)
        else {
            throw WinkBridgeOperationReceiptError.receiptMismatch(
                "successful projected response outcome")
        }
    }
}
