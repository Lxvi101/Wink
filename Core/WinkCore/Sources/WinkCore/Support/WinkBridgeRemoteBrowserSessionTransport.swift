import Foundation
import WinkAgentRuntime
import WinkAutomationKit
import WinkBridge
import WinkFoundation
import TachikomaMCP

@MainActor
protocol WinkBridgeBrowserSessionClientProviding: AnyObject, Sendable {
    func browserSessionBootstrap(
        receiptBundle: WinkBridgeOperationReceiptBundle?,
        claimID: UUID) async throws -> WinkBridgeBrowserSessionBootstrapResponse
    func browserStatus(channel: String?, sessionID: UUID?) async throws -> WinkBridgeBrowserStatus
    func browserConnectResult(
        sessionID: UUID,
        channel: String?,
        browserURL: String?) async throws -> DesktopActionResult<WinkBridgeBrowserStatus>
    func browserExecuteResult(_ request: WinkBridgeBrowserExecuteRequest) async throws
        -> DesktopActionResult<WinkBridgeBrowserToolResponse>
    func browserSessionDisconnect(_ sessionID: UUID) async throws
    func browserSessionEnd(_ sessionID: UUID) async throws
}

@MainActor
private final class WinkBridgeBrowserSessionClientAdapter: WinkBridgeBrowserSessionClientProviding,
    @unchecked Sendable
{
    private let client: WinkBridgeClient

    init(client: WinkBridgeClient) {
        self.client = client
    }

    func browserSessionBootstrap(
        receiptBundle: WinkBridgeOperationReceiptBundle?,
        claimID: UUID) async throws -> WinkBridgeBrowserSessionBootstrapResponse
    {
        try await self.client.browserSessionBootstrap(receiptBundle: receiptBundle, claimID: claimID)
    }

    func browserStatus(channel: String?, sessionID: UUID?) async throws -> WinkBridgeBrowserStatus {
        try await self.client.browserStatus(channel: channel, sessionID: sessionID)
    }

    func browserConnectResult(
        sessionID: UUID,
        channel: String?,
        browserURL: String?) async throws -> DesktopActionResult<WinkBridgeBrowserStatus>
    {
        try await self.client.browserConnectResult(
            sessionID: sessionID,
            channel: channel,
            browserURL: browserURL)
    }

    func browserExecuteResult(_ request: WinkBridgeBrowserExecuteRequest) async throws
        -> DesktopActionResult<WinkBridgeBrowserToolResponse>
    {
        try await self.client.browserExecuteResult(request)
    }

    func browserSessionDisconnect(_ sessionID: UUID) async throws {
        try await self.client.browserSessionDisconnect(sessionID)
    }

    func browserSessionEnd(_ sessionID: UUID) async throws {
        try await self.client.browserSessionEnd(sessionID)
    }
}

/// Production adapter from authenticated Bridge browser-session wire calls to the Agent runtime contract.
@MainActor
public final class WinkBridgeRemoteBrowserSessionTransport: RemoteBrowserMCPSessionTransport, @unchecked Sendable {
    private static let maximumHandoffBytes = 256 * 1024 * 1024

    private let client: any WinkBridgeBrowserSessionClientProviding

    public init(client: WinkBridgeClient) {
        self.client = WinkBridgeBrowserSessionClientAdapter(client: client)
    }

    init(client: any WinkBridgeBrowserSessionClientProviding) {
        self.client = client
    }

    public func openSession(
        handoff: BrowserMCPHandoffGrant?,
        claimID: UUID) async throws -> RemoteBrowserMCPSessionHandle
    {
        let receiptBundle = try handoff.map(Self.decodeCanonicalReceiptBundle)
        let response = try await self.mappingTerminalFailure {
            try await self.client.browserSessionBootstrap(
                receiptBundle: receiptBundle,
                claimID: claimID)
        }
        return RemoteBrowserMCPSessionHandle(
            sessionID: response.sessionID,
            targetReceiptSHA256: response.targetReceiptSHA256)
    }

    public func status(
        session: RemoteBrowserMCPSessionHandle,
        channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus
    {
        let status = try await self.mappingTerminalFailure {
            try await self.client.browserStatus(
                channel: channel?.rawValue,
                sessionID: session.sessionID)
        }
        return try RemoteBrowserMCPClient.status(from: status)
    }

    public func connectWithOutcome(
        session: RemoteBrowserMCPSessionHandle,
        channel: BrowserMCPChannel?,
        browserURL: String?) async throws -> DesktopActionResult<BrowserMCPStatus>
    {
        let result = try await self.mappingTerminalFailure {
            try await self.client.browserConnectResult(
                sessionID: session.sessionID,
                channel: channel?.rawValue,
                browserURL: browserURL)
        }
        return try DesktopActionResult(
            payload: RemoteBrowserMCPClient.status(from: result.payload),
            outcome: result.outcome)
    }

    public func executeSequenceWithOutcome(
        session: RemoteBrowserMCPSessionHandle,
        calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding,
        elementPreflight: BrowserMCPElementPreflight?) async throws -> DesktopActionResult<ToolResponse>
    {
        let bridgeCalls = try calls.map { call in
            try WinkBridgeBrowserToolCall(
                toolName: call.toolName,
                arguments: call.arguments.mapValues { try WinkBridgeJSONValue.fromAny($0) })
        }
        let bridgePreflight = elementPreflight.map {
            WinkBridgeBrowserElementPreflight(
                providerPageID: $0.providerPageID,
                providerUIDs: $0.providerUIDs.sorted())
        }
        let expectedBridgeReceipt = RemoteBrowserMCPClient.bridgeReceipt(
            from: expectedSessionBinding.connectionReceipt)
        let result = try await self.mappingTerminalFailure {
            try await self.client.browserExecuteResult(WinkBridgeBrowserExecuteRequest(
                calls: bridgeCalls,
                channel: channel?.rawValue,
                expectedConnectionReceipt: expectedBridgeReceipt,
                connectionPolicy: .requireExistingLiveReceipt,
                sessionID: session.sessionID,
                expectedProviderSessionEpoch: expectedSessionBinding.providerSessionEpoch.transportID,
                elementPreflight: bridgePreflight))
        }
        guard result.payload.connectionReceipt == expectedBridgeReceipt,
              result.payload.providerSessionEpoch == expectedSessionBinding.providerSessionEpoch.transportID
        else {
            throw Self.invalidExecutionBinding(calls: calls, outcome: result.outcome)
        }
        if result.outcome == nil, let failure = result.payload.actionFailure {
            throw failure
        }
        let response = try RemoteBrowserMCPClient.toolResponse(from: result.payload)
        return DesktopActionResult(payload: response, outcome: result.outcome)
    }

    public func disconnect(session: RemoteBrowserMCPSessionHandle) async throws {
        try await self.mappingTerminalFailure {
            try await self.client.browserSessionDisconnect(session.sessionID)
        }
    }

    public func endSession(_ session: RemoteBrowserMCPSessionHandle) async throws {
        try await self.mappingTerminalFailure {
            try await self.client.browserSessionEnd(session.sessionID)
        }
    }

    private func mappingTerminalFailure<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard let terminal = WinkBridgeClient.browserSessionTerminalFailure(from: error) else {
                throw error
            }
            throw switch terminal {
            case .invalidSession: RemoteBrowserMCPSessionTransportError.invalidSession
            case .sessionEnded: RemoteBrowserMCPSessionTransportError.sessionEnded
            case .wrongOwner: RemoteBrowserMCPSessionTransportError.wrongOwner
            case .hostGenerationChanged: RemoteBrowserMCPSessionTransportError.hostGenerationChanged
            }
        }
    }

    static func decodeCanonicalReceiptBundle(
        _ handoff: BrowserMCPHandoffGrant) throws -> WinkBridgeOperationReceiptBundle
    {
        guard !handoff.payload.isEmpty, handoff.payload.count <= self.maximumHandoffBytes else {
            throw RemoteBrowserMCPSessionError.invalidHandle
        }
        let bundle = try JSONDecoder.winkBridgeDecoder().decode(
            WinkBridgeOperationReceiptBundle.self,
            from: handoff.payload)
        let encoder = JSONEncoder.winkBridgeEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(bundle) == handoff.payload else {
            throw RemoteBrowserMCPSessionError.invalidHandle
        }
        try bundle.validate()
        return bundle
    }

    private static func invalidExecutionBinding(
        calls: [BrowserMCPMappedCall],
        outcome: DesktopActionOutcome?) -> any Error
    {
        let mutationCount = calls.count { call in
            BrowserToolActionSemantics.classify(toolName: call.toolName) { name in
                call.arguments[name] as? Bool
            } != .readOnly
        }
        guard let unitCount = outcome?.dispatchState.unitCount ??
            DesktopActionOutcome.DispatchUnitCount(mutationCount)
        else {
            return BrowserMCPConnectionError.expectedProviderSessionEpochMismatch
        }
        return DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            unitCount: unitCount,
            message: "Scoped browser execution returned a different target or provider generation.",
            hint: "Observe the browser before retrying and obtain fresh page and element references.")
    }
}
