import Darwin
import Foundation
import os.log
import WinkAutomationKit
import WinkFoundation

struct WinkBridgeClientHostAuthentication: @unchecked Sendable {
    typealias LiveIdentityProvider = @Sendable (Int32) throws -> WinkBridgeLivePeerIdentity
    typealias SigningIdentityProvider = @Sendable (WinkBridgePeerAuditIdentity)
        throws -> WinkBridgeHost.PeerSigningIdentity?

    let liveIdentity: LiveIdentityProvider
    let signingIdentity: SigningIdentityProvider
    let currentProcessIsReleaseSigned: @Sendable () -> Bool
    let unsignedDaemonPolicy: WinkBridgeUnsignedDaemonPolicy

    init(
        liveIdentity: @escaping LiveIdentityProvider = {
            try WinkBridgeSocketIO.livePeerIdentity(fd: $0)
        },
        signingIdentity: @escaping SigningIdentityProvider,
        currentProcessIsReleaseSigned: @escaping @Sendable () -> Bool =
            WinkBridgeSigningDiagnostics.currentProcessIsReleaseSigned,
        unsignedDaemonPolicy: WinkBridgeUnsignedDaemonPolicy? = nil)
    {
        self.liveIdentity = liveIdentity
        self.signingIdentity = signingIdentity
        self.currentProcessIsReleaseSigned = currentProcessIsReleaseSigned
        self.unsignedDaemonPolicy = unsignedDaemonPolicy ?? .init(
            currentProcessIsReleaseSigned: currentProcessIsReleaseSigned)
    }

    static let live = Self(
        signingIdentity: { identity in
            try WinkBridgeHost.validatedSigningIdentity(auditIdentity: identity)
        })
}

struct WinkBridgeConnectedHostIdentity: Equatable, Sendable {
    let liveIdentity: WinkBridgeLivePeerIdentity
    let signingIdentity: WinkBridgeHost.PeerSigningIdentity?
    var signingIdentityFailure: WinkBridgeCodeSignatureIdentity.SigningValidationFailure?
}

// swiftlint:disable:next type_body_length
public actor WinkBridgeClient {
    typealias TransportEnqueue = @Sendable (Date, @escaping @Sendable () -> Void) -> Void

    let socketPath: String
    let maxResponseBytes: Int
    let requestTimeoutSec: TimeInterval
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let operationReceiptExportDirectory: URL?
    let trustedHostTeamIDs: Set<String>?
    let hostAuthentication: WinkBridgeClientHostAuthentication
    let enqueueTransport: TransportEnqueue
    let logger = Logger(subsystem: "boo.wink.bridge", category: "client")
    let operationClientInstanceID: UUID
    var actionProjectionEnabled = false
    var exactDialogInputExecutionEnabled = false
    var exactDialogForceDismissExecutionEnabled = false
    var dialogInputFocusPolicyEnabled = false
    var exactFileDialogExecutionEnabled = false
    var applicationMutationInventoryTransportEnabled = false
    var windowMutationInventoryTransportEnabled = false
    private var inputCapabilities = WinkBridgeClientInputCapabilities()
    var exactWindowHeldPointerLifecycleEnabled: Bool {
        self.inputCapabilities.exactWindowHeldPointerLifecycleEnabled
    }

    var exactWindowDragEnabled: Bool {
        self.inputCapabilities.exactWindowDragEnabled
    }

    var exactWindowHeldPointerTerminalCleanupEnabled: Bool {
        self.inputCapabilities.exactWindowHeldPointerTerminalCleanupEnabled
    }

    var statelessClickVariantPayloadsEnabled: Bool {
        self.inputCapabilities.statelessClickVariantPayloadsEnabled
    }

    var statelessClickVariantsEnabled: Bool {
        self.inputCapabilities.statelessClickVariantsEnabled
    }

    var agentExecutionTraceEnabled: Bool {
        self.inputCapabilities.agentExecutionTraceEnabled
    }

    var processGenerationObservationEnabled: Bool {
        self.inputCapabilities.processGenerationObservationEnabled
    }

    var certificationProducerAttestationEnabled: Bool {
        self.inputCapabilities.certificationProducerAttestationEnabled
    }

    var setValueResultTargetBindingEnabled: Bool {
        self.inputCapabilities.setValueResultTargetBindingEnabled
    }

    var textSelectionEnabled: Bool {
        self.inputCapabilities.textSelectionEnabled
    }

    var processGenerationBoundElementMutationsEnabled: Bool {
        self.inputCapabilities.processGenerationBoundElementMutationsEnabled
    }

    var foregroundModifierClickSnapshotLeaseEnabled: Bool {
        self.inputCapabilities.foregroundModifierClickSnapshotLeaseEnabled
    }

    var nativeBrowserConnectionBindingEnabled: Bool {
        self.inputCapabilities.nativeBrowserConnectionBindingEnabled
    }

    var browserConnectionHandoffEnabled: Bool {
        self.inputCapabilities.browserConnectionHandoffEnabled
    }

    var producerBoundSnapshotReferencesEnabled: Bool {
        self.inputCapabilities.producerBoundSnapshotReferencesEnabled
    }

    var scopedMenuBarActionsEnabled: Bool {
        self.inputCapabilities.scopedMenuBarActionsEnabled
    }

    var targetedClickAccessibilityValueDeliveryEnabled: Bool {
        self.inputCapabilities.targetedClickAccessibilityValueDeliveryEnabled
    }

    var requestPinnedExactWindowScrollReceiptEnabled: Bool {
        self.inputCapabilities.requestPinnedExactWindowScrollReceiptEnabled
    }

    var backgroundCoordinateScrollEnabled: Bool {
        self.inputCapabilities.backgroundCoordinateScrollEnabled
    }

    var compositeTypeDeliveryEnabled: Bool {
        self.inputCapabilities.compositeTypeDeliveryEnabled
    }

    var clipboardGuardedExactWindowHotkeysEnabled: Bool {
        self.inputCapabilities.clipboardGuardedExactWindowHotkeysEnabled
    }

    var preparedClipboardGuardedExactWindowHotkeysEnabled: Bool {
        self.inputCapabilities.preparedClipboardGuardedExactWindowHotkeysEnabled
    }

    var desktopObservationInlinePixelsEnabled: Bool {
        self.inputCapabilities.desktopObservationInlinePixelsEnabled
    }

    var desktopObservationFreshAccessibilityTreeEnabled: Bool {
        self.inputCapabilities.desktopObservationFreshAccessibilityTreeEnabled
    }

    var operationAttestation: WinkBridgeListenerAttestation?
    var latestVerifiedOperationReceipt: WinkBridgeOperationReceipt?
    var latestVerifiedOperationReceiptBundle: WinkBridgeOperationReceiptBundle?
    var latestOperationReceiptExportFailure: WinkBridgeOperationReceiptExportFailure?

    private var operationSession: WinkBridgeClientOperationSession?
    private var operationSessionInvalidated = false
    private var handshakeEpoch: UInt64 = 0
    private var operationSessionEpoch: UInt64 = 0
    private var activeHandshakeToken: UInt64?
    private var hasSuccessfulHandshake = false
    private var lastSuccessfulHandshakeInputs: WinkBridgeClientHandshakeInputs?
    private var operationSessionRenewal: WinkBridgeClientOperationSessionRenewal?
    private var receiptlessAuthenticatedHost: WinkBridgeConnectedHostIdentity?
    private var receiptlessAuthenticationEpoch: UInt64 = 0

    /// Creates a Bridge client.
    ///
    /// Bundled Wink socket paths use the release signing teams automatically. Custom socket
    /// paths must provide `trustedHostTeamIDs` or enable the unsigned same-binary daemon policy
    /// to negotiate protocol 1.29; otherwise they negotiate receiptless protocol 1.28.
    public init(
        socketPath: String = WinkBridgeConstants.winkSocketPath,
        maxResponseBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10,
        encoder: JSONEncoder = .winkBridgeEncoder(),
        decoder: JSONDecoder = .winkBridgeDecoder(),
        operationReceiptExportDirectory: URL? = nil,
        operationClientInstanceID: UUID = UUID(),
        trustedHostTeamIDs: Set<String>? = nil)
    {
        self.socketPath = socketPath
        self.maxResponseBytes = maxResponseBytes
        self.requestTimeoutSec = requestTimeoutSec
        self.encoder = encoder
        self.decoder = decoder
        self.operationClientInstanceID = operationClientInstanceID
        self.hostAuthentication = .live
        self.trustedHostTeamIDs = Self.resolveTrustedHostTeamIDs(
            explicit: trustedHostTeamIDs,
            socketPath: socketPath) ?? (self.hostAuthentication.unsignedDaemonPolicy.enabled
            ? WinkBridgeConstants.trustedReleaseTeamIDs : nil)
        self.enqueueTransport = { _, operation in WinkBridgeBlockingIO.enqueue(operation) }
        let environmentDirectory = ProcessInfo.processInfo.environment["WINK_OPERATION_RECEIPT_DIRECTORY"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        self.operationReceiptExportDirectory = operationReceiptExportDirectory ?? environmentDirectory
    }

    #if DEBUG
    package static func authenticatedTestClient(
        socketPath: String,
        maxResponseBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10,
        operationReceiptExportDirectory: URL? = nil,
        operationClientInstanceID: UUID = UUID(),
        trustedHostTeamIDs: Set<String>,
        signingTeamIdentifier: String) -> WinkBridgeClient
    {
        WinkBridgeClient(
            socketPath: socketPath,
            maxResponseBytes: maxResponseBytes,
            requestTimeoutSec: requestTimeoutSec,
            operationReceiptExportDirectory: operationReceiptExportDirectory,
            operationClientInstanceID: operationClientInstanceID,
            trustedHostTeamIDs: trustedHostTeamIDs,
            hostAuthentication: .init(signingIdentity: { auditIdentity in
                guard let hash = WinkBridgeCodeSignatureIdentity.codeSignatureHash(
                    auditIdentity: auditIdentity)
                else { return nil }
                return WinkBridgeHost.PeerSigningIdentity(
                    bundleIdentifier: "dev.wink.test-host",
                    teamIdentifier: signingTeamIdentifier,
                    codeSignatureHash: hash)
            }))
    }
    #endif

    init(
        socketPath: String,
        maxResponseBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10,
        encoder: JSONEncoder = .winkBridgeEncoder(),
        decoder: JSONDecoder = .winkBridgeDecoder(),
        operationReceiptExportDirectory: URL? = nil,
        operationClientInstanceID: UUID = UUID(),
        trustedHostTeamIDs: Set<String>?,
        hostAuthentication: WinkBridgeClientHostAuthentication,
        enqueueTransport: @escaping TransportEnqueue = { _, operation in
            WinkBridgeBlockingIO.enqueue(operation)
        })
    {
        self.socketPath = socketPath
        self.maxResponseBytes = maxResponseBytes
        self.requestTimeoutSec = requestTimeoutSec
        self.encoder = encoder
        self.decoder = decoder
        self.operationClientInstanceID = operationClientInstanceID
        self.trustedHostTeamIDs = Self.resolveTrustedHostTeamIDs(
            explicit: trustedHostTeamIDs,
            socketPath: socketPath) ?? (hostAuthentication.unsignedDaemonPolicy.enabled
            ? WinkBridgeConstants.trustedReleaseTeamIDs : nil)
        self.hostAuthentication = hostAuthentication
        self.enqueueTransport = enqueueTransport
        let environmentDirectory = ProcessInfo.processInfo.environment["WINK_OPERATION_RECEIPT_DIRECTORY"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        self.operationReceiptExportDirectory = operationReceiptExportDirectory ?? environmentDirectory
    }

    @discardableResult
    public func handshake(
        client: WinkBridgeClientIdentity,
        requestedHost: WinkBridgeHostKind? = nil,
        protocolVersion: WinkBridgeProtocolVersion = WinkBridgeConstants.protocolVersion,
        overallTimeoutSec: TimeInterval? = nil)
        async throws -> WinkBridgeHandshakeResponse
    {
        let effectiveProtocolVersion = self.effectiveHandshakeProtocolVersion(protocolVersion)
        let inputs = WinkBridgeClientHandshakeInputs(
            client: client,
            requestedHost: requestedHost,
            protocolVersion: effectiveProtocolVersion,
            allowsProtocolFallback: protocolVersion == WinkBridgeConstants.protocolVersion)
        let replacingSessionID = self.operationSession?.attestation.sessionID
        let deadline = try self.handshakeDeadline(overallTimeoutSec: overallTimeoutSec)
        let token = self.beginHandshake(supersedingRenewal: true)
        do {
            let candidate: WinkBridgeClientHandshakeCandidate
            let candidateReplacingSessionID: UUID?
            do {
                candidate = try await self.negotiateHandshake(
                    inputs: inputs,
                    replacingOperationSessionID: replacingSessionID,
                    overallTimeoutSec: self.remainingOverallHandshakeTimeout(deadline: deadline),
                    token: token)
                candidateReplacingSessionID = replacingSessionID
            } catch {
                guard replacingSessionID != nil,
                      Self.canRetryFreshHandshake(after: error)
                else { throw error }
                try self.checkHandshakeToken(token)
                candidate = try await self.negotiateHandshake(
                    inputs: inputs,
                    replacingOperationSessionID: nil,
                    overallTimeoutSec: self.remainingOverallHandshakeTimeout(deadline: deadline),
                    token: token)
                candidateReplacingSessionID = nil
            }
            try self.installHandshakeCandidate(
                candidate,
                inputs: inputs,
                token: token,
                replacingSessionID: candidateReplacingSessionID,
                allowLegacyReplacement: true)
            return candidate.response
        } catch {
            self.finishHandshakeAttempt(token: token)
            throw error
        }
    }

    public func authenticatedHostIdentity() -> WinkBridgeAuthenticatedHostIdentity? {
        self.operationSession?.authenticatedHostIdentity
    }

    /// Most recent protocol-1.29 receipt accepted by this client after signature and digest validation.
    public func lastOperationReceipt() -> WinkBridgeOperationReceipt? {
        self.latestVerifiedOperationReceipt
    }

    /// Most recent full audit bundle. It contains the complete request and response payload bytes.
    public func lastOperationReceiptBundle() -> WinkBridgeOperationReceiptBundle? {
        self.latestVerifiedOperationReceiptBundle
    }

    /// Most recent requested receipt export that failed after the response bundle was verified successfully.
    public func lastOperationReceiptExportFailure() -> WinkBridgeOperationReceiptExportFailure? {
        self.latestOperationReceiptExportFailure
    }

    func usesExplicitReceiptlessTransport() -> Bool {
        self.hasSuccessfulHandshake && self.operationAttestation == nil
    }

    func receiptlessAuthenticatedHostReservation() -> WinkBridgeReceiptlessHostReservation? {
        guard self.hasSuccessfulHandshake,
              self.operationAttestation == nil,
              let host = self.receiptlessAuthenticatedHost
        else { return nil }
        return .init(epoch: self.receiptlessAuthenticationEpoch, host: host)
    }

    /// Reserves one unique slot in the currently negotiated receipt session before transport suspends.
    ///
    /// The local remaining count is deliberately conservative. A failed request can consume a server claim,
    /// so only a verified signed receipt or a new session can establish a newer budget.
    func reserveOperationSession() throws -> WinkBridgeClientOperationSessionReservation? {
        let publicHandshakeInProgress = self.activeHandshakeToken != nil && self.operationSessionRenewal == nil
        let attestedSessionIsUnusable = self.operationAttestation != nil &&
            (self.operationSessionInvalidated || self.operationSessionRequiresRenewal())
        if publicHandshakeInProgress,
           !self.hasSuccessfulHandshake || attestedSessionIsUnusable
        {
            throw WinkBridgeClientOperationSessionError.negotiationInProgress
        }
        guard self.operationAttestation != nil else {
            guard self.hasSuccessfulHandshake else {
                throw WinkBridgeClientOperationSessionError.handshakeRequired
            }
            return nil
        }
        guard var session = self.operationSession else {
            throw WinkBridgeClientOperationSessionError.unavailable
        }
        if self.operationSessionInvalidated {
            throw WinkBridgeClientOperationSessionError.renewalRequired(
                sessionID: session.attestation.sessionID,
                epoch: session.epoch)
        }
        let maximumRequestCount = session.attestation.maximumRequestCount
        let shouldRenewProactively = maximumRequestCount > 1 && session.remainingClaimCount <= 1
        guard !shouldRenewProactively,
              session.remainingClaimCount > 0,
              session.nextSequence.value < UInt64(maximumRequestCount)
        else {
            throw WinkBridgeClientOperationSessionError.renewalRequired(
                sessionID: session.attestation.sessionID,
                epoch: session.epoch)
        }

        let sequence = session.nextSequence
        let nextValue = sequence.value.addingReportingOverflow(1)
        guard !nextValue.overflow else {
            throw WinkBridgeClientOperationSessionError.renewalRequired(
                sessionID: session.attestation.sessionID,
                epoch: session.epoch)
        }
        session.nextSequence = WinkBridgeOperationSessionSequence(nextValue.partialValue)
        session.remainingClaimCount -= 1
        self.operationSession = session
        return WinkBridgeClientOperationSessionReservation(
            epoch: session.epoch,
            listenerAttestation: session.listenerAttestation,
            listenerLiveIdentity: session.listenerLiveIdentity,
            hostBuild: session.hostBuild,
            sessionAttestation: session.attestation,
            sequence: sequence,
            requestID: WinkBridgeOperationReceiptCoding.deterministicRequestID(
                sessionID: session.attestation.sessionID,
                sequence: sequence),
            clientIdentity: session.attestation.client)
    }

    func operationSessionRequiresRenewal() -> Bool {
        guard self.operationAttestation != nil else { return false }
        guard !self.operationSessionInvalidated else { return true }
        guard let session = self.operationSession else { return true }
        return session.remainingClaimCount <= (session.attestation.maximumRequestCount > 1 ? 1 : 0) ||
            session.nextSequence.value >= UInt64(session.attestation.maximumRequestCount)
    }

    /// Installs a successor carried by a fully verified rollover refusal.
    @discardableResult
    func installOperationSession(
        _ successor: WinkBridgeOperationSessionAttestation,
        listenerAttestation: WinkBridgeListenerAttestation,
        replacingSessionID: UUID,
        expectedEpoch: UInt64) throws -> UInt64
    {
        if let current = self.operationSession,
           current.attestation.sessionID == successor.sessionID
        {
            self.cancelOperationSessionRenewal(replacingSessionID: replacingSessionID)
            return current.epoch
        }
        guard let current = self.operationSession,
              current.epoch == expectedEpoch,
              current.attestation.sessionID == replacingSessionID,
              current.listenerAttestation == listenerAttestation,
              self.operationAttestation == listenerAttestation
        else {
            throw WinkBridgeClientOperationSessionError.superseded
        }
        try self.validateOperationSession(
            successor,
            listenerAttestation: listenerAttestation,
            replacingSessionID: replacingSessionID)
        self.cancelOperationSessionRenewal(replacingSessionID: replacingSessionID)
        return self.installOperationSessionState(
            successor,
            listenerAttestation: listenerAttestation,
            listenerLiveIdentity: current.listenerLiveIdentity,
            hostBuild: current.hostBuild,
            authenticatedHostIdentity: current.authenticatedHostIdentity)
    }

    private func cancelOperationSessionRenewal(replacingSessionID: UUID) {
        guard let renewal = self.operationSessionRenewal,
              renewal.replacingSessionID == replacingSessionID
        else { return }
        renewal.task.cancel()
        self.finishOperationSessionRenewalAttempt(renewal)
    }

    /// Applies signed budget progress only to the exact session that issued the request.
    func recordOperationSessionReceipt(
        sessionID: UUID,
        epoch: UInt64,
        remainingClaimCount: Int)
    {
        guard var current = self.operationSession,
              !self.operationSessionInvalidated,
              current.epoch == epoch,
              current.attestation.sessionID == sessionID,
              remainingClaimCount >= 0,
              remainingClaimCount <= current.attestation.maximumRequestCount
        else { return }
        current.remainingClaimCount = min(current.remainingClaimCount, remainingClaimCount)
        self.operationSession = current
    }

    /// Publishes a verified bundle only while its session is still current.
    /// Old in-flight responses remain valid to their caller but cannot repopulate post-rollover shared state.
    func recordOperationReceiptBundle(
        _ bundle: WinkBridgeOperationReceiptBundle,
        reservation: WinkBridgeClientOperationSessionReservation)
    {
        guard self.operationSession?.epoch == reservation.epoch,
              !self.operationSessionInvalidated,
              self.operationSession?.attestation.sessionID == reservation.sessionAttestation.sessionID,
              self.operationAttestation == reservation.listenerAttestation
        else { return }
        self.recordOperationSessionReceipt(
            sessionID: reservation.sessionAttestation.sessionID,
            epoch: reservation.epoch,
            remainingClaimCount: bundle.receipt.payload.remainingClaimCount)
        self.latestVerifiedOperationReceipt = bundle.receipt
        self.latestVerifiedOperationReceiptBundle = bundle
    }

    /// Prevents future calls from using a session after any request that did not yield a valid receipt.
    /// Already in-flight requests keep their captured reservation and may still validate independently.
    func invalidateOperationSession(sessionID: UUID, epoch: UInt64) {
        guard self.operationSession?.epoch == epoch,
              self.operationSession?.attestation.sessionID == sessionID
        else { return }
        self.operationSessionInvalidated = true
        self.latestVerifiedOperationReceipt = nil
        self.latestVerifiedOperationReceiptBundle = nil
    }

    /// Requires an explicit cold recovery handshake without authorizing a retry of the request that exposed the
    /// replacement. The disabled session identity remains available so that handshake can first offer to retire it.
    func requireColdHandshakeRetainingOperationSession(sessionID: UUID, epoch: UInt64) {
        guard self.operationSession?.epoch == epoch,
              self.operationSession?.attestation.sessionID == sessionID
        else { return }
        self.operationAttestation = nil
        self.operationSessionInvalidated = true
        self.hasSuccessfulHandshake = false
        self.clearNegotiatedInputCapabilities()
        self.latestVerifiedOperationReceipt = nil
        self.latestVerifiedOperationReceiptBundle = nil
    }

    /// Applies transport evidence only to the exact session that reserved the failed request.
    ///
    /// A kernel-proven peer replacement can never produce a receipt from the cached listener. Keep its predecessor
    /// identity for recovery, but do not let later callers enter a doomed automatic renewal loop against that listener.
    func recordOperationSessionTransportFailure(
        _ error: any Error,
        sessionID: UUID,
        epoch: UInt64)
    {
        if Self.operationSessionFailureRequiresColdHandshake(error) {
            self.requireColdHandshakeRetainingOperationSession(sessionID: sessionID, epoch: epoch)
        } else {
            self.invalidateOperationSession(sessionID: sessionID, epoch: epoch)
        }
    }

    func invalidateReceiptlessAuthenticatedHost(
        reservation: WinkBridgeReceiptlessHostReservation?)
    {
        guard let reservation,
              self.operationAttestation == nil,
              self.receiptlessAuthenticationEpoch == reservation.epoch,
              self.receiptlessAuthenticatedHost == reservation.host
        else { return }
        self.receiptlessAuthenticatedHost = nil
        self.hasSuccessfulHandshake = false
        self.clearNegotiatedInputCapabilities()
        self.latestVerifiedOperationReceipt = nil
        self.latestVerifiedOperationReceiptBundle = nil
    }

    func clearNegotiatedInputCapabilities() {
        self.inputCapabilities = WinkBridgeClientInputCapabilities()
    }

    /// Creates or joins one successor-session handshake using the most recent successful public inputs.
    @discardableResult
    func renewOperationSession(
        replacingSessionID: UUID,
        overallTimeoutSec: TimeInterval? = nil) async throws -> WinkBridgeOperationSessionAttestation
    {
        if let successor = self.installedOperationSessionSuccessor(replacingSessionID: replacingSessionID) {
            return successor
        }
        if let renewal = self.operationSessionRenewal {
            guard renewal.replacingSessionID == replacingSessionID else {
                throw WinkBridgeClientOperationSessionError.superseded
            }
            do {
                let candidate = try await Self.awaitOperationSessionRenewal(
                    renewal.task,
                    timeoutSec: overallTimeoutSec ?? self.requestTimeoutSec)
                return try self.finishOperationSessionRenewal(candidate, renewal: renewal)
            } catch {
                if let successor = self.installedOperationSessionSuccessor(
                    replacingSessionID: replacingSessionID)
                {
                    return successor
                }
                let normalizedError = Self.normalizedOperationSessionRenewalError(error)
                self.recordDefinitiveOperationSessionRenewalFailure(normalizedError, renewal: renewal)
                throw normalizedError
            }
        }
        guard let inputs = self.lastSuccessfulHandshakeInputs,
              let current = self.operationSession,
              current.attestation.sessionID == replacingSessionID
        else {
            throw WinkBridgeClientOperationSessionError.unavailable
        }

        let token = self.beginHandshake(supersedingRenewal: false)
        let renewalTransportTimeoutSec = self.requestTimeoutSec
        let task = Task { [inputs] in
            try await self.negotiateHandshake(
                inputs: inputs,
                replacingOperationSessionID: replacingSessionID,
                overallTimeoutSec: renewalTransportTimeoutSec,
                token: token)
        }
        let renewal = WinkBridgeClientOperationSessionRenewal(
            replacingSessionID: replacingSessionID,
            predecessorEpoch: current.epoch,
            token: token,
            task: task)
        self.operationSessionRenewal = renewal
        Task {
            do {
                let candidate = try await task.value
                self.operationSessionRenewalTaskDidSucceed(candidate, renewal: renewal)
            } catch {
                self.operationSessionRenewalTaskDidFail(error, renewal: renewal)
            }
        }
        do {
            let candidate = try await Self.awaitOperationSessionRenewal(
                task,
                timeoutSec: overallTimeoutSec ?? self.requestTimeoutSec)
            return try self.finishOperationSessionRenewal(candidate, renewal: renewal)
        } catch {
            if let successor = self.installedOperationSessionSuccessor(
                replacingSessionID: replacingSessionID)
            {
                return successor
            }
            let normalizedError = Self.normalizedOperationSessionRenewalError(error)
            self.recordDefinitiveOperationSessionRenewalFailure(normalizedError, renewal: renewal)
            throw normalizedError
        }
    }

    private func installedOperationSessionSuccessor(
        replacingSessionID: UUID) -> WinkBridgeOperationSessionAttestation?
    {
        guard !self.operationSessionInvalidated,
              let current = self.operationSession,
              current.attestation.predecessorSessionID == replacingSessionID,
              self.operationAttestation == current.listenerAttestation
        else { return nil }
        return current.attestation
    }

    private func operationSessionRenewalTaskDidSucceed(
        _ candidate: WinkBridgeClientHandshakeCandidate,
        renewal: WinkBridgeClientOperationSessionRenewal)
    {
        guard self.operationSessionRenewal?.token == renewal.token else { return }
        do {
            _ = try self.finishOperationSessionRenewal(candidate, renewal: renewal)
        } catch {
            self.finishOperationSessionRenewalAttempt(renewal)
        }
    }

    private func operationSessionRenewalTaskDidFail(
        _ error: any Error,
        renewal: WinkBridgeClientOperationSessionRenewal)
    {
        guard self.operationSessionRenewal?.token == renewal.token else { return }
        self.recordDefinitiveOperationSessionRenewalFailure(error, renewal: renewal)
        self.finishOperationSessionRenewalAttempt(renewal)
    }

    private func recordDefinitiveOperationSessionRenewalFailure(
        _ error: any Error,
        renewal: WinkBridgeClientOperationSessionRenewal)
    {
        guard Self.operationSessionFailureRequiresColdHandshake(error) else { return }
        self.requireColdHandshakeRetainingOperationSession(
            sessionID: renewal.replacingSessionID,
            epoch: renewal.predecessorEpoch)
    }

    private func finishOperationSessionRenewal(
        _ candidate: WinkBridgeClientHandshakeCandidate,
        renewal: WinkBridgeClientOperationSessionRenewal) throws
        -> WinkBridgeOperationSessionAttestation
    {
        if let current = self.installedOperationSessionSuccessor(
            replacingSessionID: renewal.replacingSessionID)
        {
            self.finishOperationSessionRenewalAttempt(renewal)
            return current
        }
        try self.checkHandshakeToken(renewal.token)
        guard self.operationSession?.epoch == renewal.predecessorEpoch,
              self.operationSession?.attestation.sessionID == renewal.replacingSessionID
        else {
            self.finishOperationSessionRenewalAttempt(renewal)
            throw WinkBridgeClientOperationSessionError.superseded
        }
        if candidate.response.negotiatedVersion < WinkBridgeConstants.attestedOperationReceiptVersion {
            // Automatic renewal must never turn the waiting operation into a receiptless request. Preserve the
            // predecessor only so a later explicit handshake can authorize the legacy downgrade deliberately.
            self.requireColdHandshakeRetainingOperationSession(
                sessionID: renewal.replacingSessionID,
                epoch: renewal.predecessorEpoch)
            self.finishOperationSessionRenewalAttempt(renewal)
            throw WinkBridgeClientOperationSessionError.handshakeRequired
        }
        try self.installHandshakeCandidate(
            candidate,
            inputs: self.lastSuccessfulHandshakeInputs,
            token: renewal.token,
            replacingSessionID: renewal.replacingSessionID)
        self.finishOperationSessionRenewalAttempt(renewal)
        guard let session = self.operationSession?.attestation else {
            throw WinkBridgeClientOperationSessionError.unavailable
        }
        return session
    }

    private func finishOperationSessionRenewalAttempt(
        _ renewal: WinkBridgeClientOperationSessionRenewal)
    {
        if self.operationSessionRenewal?.token == renewal.token {
            self.operationSessionRenewal = nil
        }
        self.finishHandshakeAttempt(token: renewal.token)
    }

    /// Bounds each caller's wait without cancelling the shared renewal needed by concurrent callers.
    private nonisolated static func awaitOperationSessionRenewal(
        _ task: Task<WinkBridgeClientHandshakeCandidate, any Error>,
        timeoutSec: TimeInterval) async throws -> WinkBridgeClientHandshakeCandidate
    {
        guard timeoutSec.isFinite, timeoutSec > 0 else { throw POSIXError(.ETIMEDOUT) }
        let waiter = WinkBridgeClientOperationSessionRenewalWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                Task {
                    do {
                        try await waiter.finish(.success(task.value))
                    } catch {
                        waiter.finish(.failure(error))
                    }
                }
                Task {
                    do {
                        try await Task.sleep(for: .seconds(timeoutSec))
                        waiter.finish(.failure(POSIXError(.ETIMEDOUT)))
                    } catch {
                        // The timeout worker is best-effort; cancellation is delivered by the handler below.
                    }
                }
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }

    private func negotiateHandshake(
        inputs: WinkBridgeClientHandshakeInputs,
        replacingOperationSessionID: UUID?,
        overallTimeoutSec: TimeInterval?,
        token: UInt64) async throws -> WinkBridgeClientHandshakeCandidate
    {
        let deadline = try self.handshakeDeadline(overallTimeoutSec: overallTimeoutSec)
        do {
            try self.checkHandshakeToken(token)
            return try await self.performHandshake(
                inputs: inputs,
                protocolVersion: inputs.protocolVersion,
                replacingOperationSessionID: replacingOperationSessionID,
                timeoutSec: self.remainingHandshakeTimeout(deadline: deadline))
        } catch let envelope as WinkBridgeErrorEnvelope
            where envelope.code == .versionMismatch &&
            inputs.allowsProtocolFallback &&
            WinkBridgeConstants.minimumProtocolVersion < inputs.protocolVersion
        {
            var version = WinkBridgeProtocolVersion(
                major: inputs.protocolVersion.major,
                minor: inputs.protocolVersion.minor - 1)
            while version >= WinkBridgeConstants.minimumProtocolVersion {
                do {
                    try self.checkHandshakeToken(token)
                    return try await self.performHandshake(
                        inputs: inputs,
                        protocolVersion: version,
                        replacingOperationSessionID: replacingOperationSessionID,
                        timeoutSec: self.remainingHandshakeTimeout(deadline: deadline))
                } catch let fallbackEnvelope as WinkBridgeErrorEnvelope
                    where fallbackEnvelope.code == .versionMismatch
                {
                    version = WinkBridgeProtocolVersion(major: version.major, minor: version.minor - 1)
                }
            }
            throw envelope
        }
    }

    nonisolated static func offeredCapabilities(for protocolVersion: WinkBridgeProtocolVersion) -> [String] {
        var capabilities: [String] = []
        if protocolVersion >= WinkBridgeConstants.attestedOperationReceiptVersion {
            capabilities.append(WinkBridgeClientCapability.screenCaptureKitOwnershipDiagnostics)
        }
        if protocolVersion >= WinkBridgeConstants.producerBoundSnapshotReferencesVersion {
            capabilities.append(WinkBridgeClientCapability.producerBoundSnapshotReferences)
            capabilities.append(WinkBridgeClientCapability.targetedClickAccessibilityValueDelivery)
        }
        if protocolVersion >= WinkBridgeConstants.processGenerationBoundElementMutationsVersion {
            capabilities.append(WinkBridgeClientCapability.setValueVerification)
        }
        if protocolVersion >= WinkBridgeConstants.browserConnectionHandoffVersion {
            capabilities.append(WinkBridgeClientCapability.browserConnectionHandoff)
        }
        if protocolVersion >= WinkBridgeConstants.scopedMenuBarActionsVersion {
            capabilities.append(WinkBridgeClientCapability.scopedMenuBarActions)
        }
        return capabilities
    }

    private func performHandshake(
        inputs: WinkBridgeClientHandshakeInputs,
        protocolVersion: WinkBridgeProtocolVersion,
        replacingOperationSessionID: UUID?,
        timeoutSec: TimeInterval?) async throws -> WinkBridgeClientHandshakeCandidate
    {
        let payload = WinkBridgeHandshake(
            protocolVersion: protocolVersion,
            client: inputs.client,
            requestedHostKind: inputs.requestedHost,
            operationClientInstanceID: self.operationClientInstanceID,
            replacingOperationSessionID: replacingOperationSessionID,
            clientCapabilities: protocolVersion >= WinkBridgeConstants.attestedOperationReceiptVersion
                ? Self.offeredCapabilities(for: protocolVersion)
                : nil)
        let reply = try await self.sendCarryingActionOutcome(.handshake(payload), timeoutSec: timeoutSec)
        let response = reply.response
        let hostKind: WinkBridgeHostKind? = if case let .handshake(handshake) = response {
            handshake.hostKind
        } else {
            nil
        }
        let trustMode = try self.validateTrustedConnectedHost(reply.connectedHost, hostKind: hostKind)

        switch response {
        case var .handshake(handshake):
            handshake.trustMode = trustMode
            return try self.handshakeCandidate(
                handshake,
                replacingOperationSessionID: replacingOperationSessionID,
                connectedHost: reply.connectedHost)
        case let .error(envelope):
            throw envelope
        default:
            throw WinkBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected handshake response")
        }
    }

    /// Validates the kernel-connected host before interpreting any trusted-socket handshake response, including
    /// errors that could otherwise trigger protocol fallback. Custom sockets without an explicit trust policy retain
    /// their intentionally unauthenticated protocol-1.28 compatibility behavior.
    private func validateTrustedConnectedHost(
        _ connectedHost: WinkBridgeConnectedHostIdentity?,
        hostKind: WinkBridgeHostKind?) throws -> WinkBridgeTrustMode?
    {
        guard let trustedHostTeamIDs = self.trustedHostTeamIDs else { return nil }
        return try WinkBridgeConnectedHostTrust.validate(
            connectedHost,
            socketPath: self.socketPath,
            trustedTeamIDs: trustedHostTeamIDs,
            hostKind: hostKind,
            unsignedDaemonPolicy: self.hostAuthentication.unsignedDaemonPolicy,
            currentProcessIsReleaseSigned: self.hostAuthentication.currentProcessIsReleaseSigned)
    }

    private func handshakeCandidate(
        _ handshake: WinkBridgeHandshakeResponse,
        replacingOperationSessionID: UUID?,
        connectedHost: WinkBridgeConnectedHostIdentity?) throws -> WinkBridgeClientHandshakeCandidate
    {
        let authentication = try self.handshakeAuthentication(
            handshake,
            replacingOperationSessionID: replacingOperationSessionID,
            connectedHost: connectedHost)
        let exactInputAdvertised = handshake.supportedOperations.contains(.exactDialogEnterText)
        let exactForceDismissAdvertised = handshake.supportedOperations.contains(.exactDialogForceDismiss)
        let legacyInputAdvertised = handshake.supportedOperations.contains(.dialogEnterText)
        let exactFileAdvertised = handshake.supportedOperations.contains(.dialogHandleFile)
        return WinkBridgeClientHandshakeCandidate(
            response: handshake,
            actionProjectionEnabled:
            handshake.negotiatedVersion >= WinkBridgeConstants.desktopActionOutcomeProjectionVersion &&
                handshake.hostCapabilities?.contains(
                    WinkBridgeHostCapability.desktopActionOutcomeProjection) == true,
            exactDialogInputExecutionEnabled:
            handshake.negotiatedVersion >= WinkBridgeConstants.exactDialogInputExecutionVersion &&
                exactInputAdvertised &&
                (handshake.enabledOperations?.contains(.exactDialogEnterText) ?? exactInputAdvertised) &&
                handshake.hostCapabilities?.contains(
                    WinkBridgeHostCapability.exactDialogInputExecution) == true,
            exactDialogForceDismissExecutionEnabled:
            handshake.negotiatedVersion >= WinkBridgeConstants.exactForcedDialogDismissExecutionVersion &&
                exactForceDismissAdvertised &&
                (handshake.enabledOperations?.contains(.exactDialogForceDismiss) ?? exactForceDismissAdvertised) &&
                handshake.hostCapabilities?.contains(
                    WinkBridgeHostCapability.exactForcedDialogDismissExecution) == true,
            dialogInputFocusPolicyEnabled:
            handshake.negotiatedVersion >= WinkBridgeConstants.dialogInputFocusPolicyVersion &&
                legacyInputAdvertised &&
                (handshake.enabledOperations?.contains(.dialogEnterText) ?? legacyInputAdvertised) &&
                handshake.hostCapabilities?.contains(
                    WinkBridgeHostCapability.dialogInputFocusPolicy) == true,
            exactFileDialogExecutionEnabled:
            handshake.negotiatedVersion >= WinkBridgeConstants.exactFileDialogExecutionVersion &&
                authentication.sessionAttestation != nil &&
                exactFileAdvertised &&
                handshake.enabledOperations?.contains(.dialogHandleFile) == true &&
                handshake.hostCapabilities?.contains(
                    WinkBridgeHostCapability.exactFileDialogExecution) == true,
            applicationMutationInventoryTransportEnabled:
            handshake.negotiatedVersion >= WinkBridgeConstants.plannerInventoryTransportVersion &&
                handshake.hostCapabilities?.contains(
                    WinkBridgeHostCapability.plannerInventoryTransport) == true &&
                handshake.supportedOperations.contains(.listApplications) &&
                (handshake.enabledOperations?.contains(.listApplications) ?? true),
            windowMutationInventoryTransportEnabled:
            handshake.negotiatedVersion >= WinkBridgeConstants.plannerInventoryTransportVersion &&
                handshake.hostCapabilities?.contains(
                    WinkBridgeHostCapability.plannerInventoryTransport) == true &&
                handshake.supportedOperations.contains(.listWindows) &&
                (handshake.enabledOperations?.contains(.listWindows) ?? true),
            inputCapabilities: .init(
                exactWindowHeldPointerLifecycleEnabled:
                handshake.negotiatedVersion >= WinkBridgeConstants.exactWindowHeldPointerLifecycleVersion &&
                    handshake.hostCapabilities?.contains(
                        WinkBridgeHostCapability.exactWindowHeldPointerLifecycle) == true &&
                    Set([
                        WinkBridgeOperation.createExactWindowHeldPointerOwner,
                        .beginExactWindowHeldPointer,
                        .releaseExactWindowHeldPointer,
                        .revokeExactWindowHeldPointer,
                        .disconnectExactWindowHeldPointerOwner,
                    ]).isSubset(of: Set(handshake.supportedOperations)) &&
                    Set([
                        WinkBridgeOperation.createExactWindowHeldPointerOwner,
                        .beginExactWindowHeldPointer,
                    ]).isSubset(of: Set(handshake.enabledOperations ?? handshake.supportedOperations)),
                exactWindowDragEnabled: handshake.supportsExactWindowDrag,
                exactWindowHeldPointerTerminalCleanupEnabled:
                handshake.negotiatedVersion >= WinkBridgeConstants.exactWindowHeldPointerLifecycleVersion &&
                    handshake.hostCapabilities?.contains(
                        WinkBridgeHostCapability.exactWindowHeldPointerLifecycle) == true &&
                    Set([
                        WinkBridgeOperation.createExactWindowHeldPointerOwner,
                        .beginExactWindowHeldPointer,
                        .releaseExactWindowHeldPointer,
                        .revokeExactWindowHeldPointer,
                        .disconnectExactWindowHeldPointerOwner,
                    ]).isSubset(of: Set(handshake.supportedOperations)) &&
                    Set([
                        WinkBridgeOperation.releaseExactWindowHeldPointer,
                        .revokeExactWindowHeldPointer,
                        .disconnectExactWindowHeldPointerOwner,
                    ]).isSubset(of: Set(handshake.enabledOperations ?? handshake.supportedOperations)),
                statelessClickVariantPayloadsEnabled:
                handshake.negotiatedVersion >= WinkBridgeConstants.statelessClickVariantVersion,
                statelessClickVariantsEnabled: Self.supportsStatelessClickVariants(handshake),
                agentExecutionTraceEnabled: Self.supportsAgentExecutionTrace(handshake),
                processGenerationObservationEnabled: Self.supportsProcessGenerationObservation(handshake),
                certificationProducerAttestationEnabled: Self.supportsCertificationProducerAttestation(handshake),
                setValueResultTargetBindingEnabled: Self.supportsSetValueResultTargetBinding(handshake),
                textSelectionEnabled: handshake.negotiatedVersion >= WinkBridgeConstants.textSelectionVersion &&
                    handshake.hostCapabilities?.contains(WinkBridgeHostCapability.textSelection) == true &&
                    handshake.supportedOperations.contains(.selectText) &&
                    (handshake.enabledOperations?.contains(.selectText) ?? true),
                processGenerationBoundElementMutationsEnabled:
                Self.supportsProcessGenerationBoundElementMutations(handshake),
                foregroundModifierClickSnapshotLeaseEnabled:
                Self.supportsForegroundModifierClickSnapshotLease(handshake),
                nativeBrowserConnectionBindingEnabled:
                Self.supportsNativeBrowserConnectionBinding(handshake),
                browserConnectionHandoffEnabled:
                Self.supportsBrowserConnectionHandoff(handshake),
                producerBoundSnapshotReferencesEnabled:
                Self.supportsProducerBoundSnapshotReferences(handshake),
                scopedMenuBarActionsEnabled: handshake.supportsScopedMenuBarActions,
                targetedClickAccessibilityValueDeliveryEnabled:
                Self.supportsTargetedClickAccessibilityValueDelivery(handshake),
                requestPinnedExactWindowScrollReceiptEnabled:
                handshake.supportsRequestPinnedExactWindowScrollReceipt,
                backgroundCoordinateScrollEnabled: handshake.supportsBackgroundCoordinateScroll,
                compositeTypeDeliveryEnabled: Self.supportsCompositeTypeDelivery(handshake),
                clipboardGuardedExactWindowHotkeysEnabled: handshake.supportsClipboardGuardedExactWindowHotkeys,
                preparedClipboardGuardedExactWindowHotkeysEnabled: handshake
                    .supportsPreparedClipboardGuardedExactWindowHotkeys,
                desktopObservationInlinePixelsEnabled: handshake.supportedOperations.contains(.desktopObservation) &&
                    handshake.hostCapabilities?
                    .contains(WinkBridgeHostCapability.desktopObservationInlinePixels) == true,
                desktopObservationFreshAccessibilityTreeEnabled:
                handshake.supportsDesktopObservationFreshAccessibilityTree),
            listenerAttestation: authentication.listenerAttestation,
            listenerLiveIdentity: authentication.listenerLiveIdentity,
            sessionAttestation: authentication.sessionAttestation,
            authenticatedHostIdentity: authentication.authenticatedHostIdentity,
            receiptlessAuthenticatedHost: authentication.receiptlessAuthenticatedHost)
    }

    private struct HandshakeAuthentication {
        let listenerAttestation: WinkBridgeListenerAttestation?
        let listenerLiveIdentity: WinkBridgeLivePeerIdentity?
        let sessionAttestation: WinkBridgeOperationSessionAttestation?
        let authenticatedHostIdentity: WinkBridgeAuthenticatedHostIdentity?
        let receiptlessAuthenticatedHost: WinkBridgeConnectedHostIdentity?
    }

    private func handshakeAuthentication(
        _ handshake: WinkBridgeHandshakeResponse,
        replacingOperationSessionID: UUID?,
        connectedHost: WinkBridgeConnectedHostIdentity?) throws -> HandshakeAuthentication
    {
        let listenerAttestation: WinkBridgeListenerAttestation?
        let listenerLiveIdentity: WinkBridgeLivePeerIdentity?
        let sessionAttestation: WinkBridgeOperationSessionAttestation?
        let receiptlessAuthenticatedHost: WinkBridgeConnectedHostIdentity?
        let authenticatedHostIdentity: WinkBridgeAuthenticatedHostIdentity?
        if handshake.negotiatedVersion >= WinkBridgeConstants.attestedOperationReceiptVersion {
            guard handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.attestedOperationReceipts) == true,
                handshake.hostCapabilities?.contains(
                    WinkBridgeHostCapability.desktopActionOutcomeProjection) == true,
                let advertisedListenerAttestation = handshake.operationAttestation,
                let advertisedSessionAttestation = handshake.operationSessionAttestation
            else {
                throw WinkBridgeErrorEnvelope(
                    code: .unauthorizedClient,
                    message: "Protocol 1.29 Bridge host omitted required operation receipt capabilities")
            }
            guard let connectedHost,
                  let liveCodeSignatureHash = connectedHost.liveIdentity.codeSignatureHash,
                  !liveCodeSignatureHash.isEmpty,
                  handshake.trustMode != nil,
                  connectedHost.liveIdentity.processIdentifier == advertisedListenerAttestation.host.processIdentifier,
                  connectedHost.liveIdentity.processStartIdentity ==
                  advertisedListenerAttestation.host.processStartIdentity,
                  liveCodeSignatureHash == advertisedListenerAttestation.host.codeSignatureHash
            else {
                throw WinkBridgeErrorEnvelope(
                    code: .unauthorizedClient,
                    message: "Bridge listener does not match the trusted connected host")
            }
            do {
                try advertisedListenerAttestation.validateSignature()
                try self.validateOperationSession(
                    advertisedSessionAttestation,
                    listenerAttestation: advertisedListenerAttestation,
                    replacingSessionID: replacingOperationSessionID)
            } catch {
                throw WinkBridgeErrorEnvelope(
                    code: .unauthorizedClient,
                    message: "Bridge operation session attestation is invalid",
                    details: error.localizedDescription)
            }
            guard let advertisedHostIdentity = handshake.hostIdentity,
                  advertisedHostIdentity.processIdentifier == advertisedListenerAttestation.host.processIdentifier,
                  advertisedHostIdentity.processStartIdentity ==
                  advertisedListenerAttestation.host.processStartIdentity,
                  advertisedHostIdentity.codeSignatureHash == advertisedListenerAttestation.host.codeSignatureHash
            else {
                throw WinkBridgeErrorEnvelope(
                    code: .unauthorizedClient,
                    message: "Bridge listener attestation contradicts the advertised host identity")
            }
            listenerAttestation = advertisedListenerAttestation
            listenerLiveIdentity = connectedHost.liveIdentity
            sessionAttestation = advertisedSessionAttestation
            receiptlessAuthenticatedHost = nil
            if handshake.trustMode == .releaseSignature, let signingIdentity = connectedHost.signingIdentity {
                authenticatedHostIdentity = Self.authenticatedHostIdentity(
                    advertised: advertisedHostIdentity,
                    listener: advertisedListenerAttestation,
                    signingIdentity: signingIdentity)
            } else {
                authenticatedHostIdentity = nil
            }
        } else {
            listenerAttestation = nil
            listenerLiveIdentity = nil
            sessionAttestation = nil
            receiptlessAuthenticatedHost = self.trustedHostTeamIDs == nil ? nil : connectedHost
            authenticatedHostIdentity = nil
        }

        return HandshakeAuthentication(
            listenerAttestation: listenerAttestation,
            listenerLiveIdentity: listenerLiveIdentity,
            sessionAttestation: sessionAttestation,
            authenticatedHostIdentity: authenticatedHostIdentity,
            receiptlessAuthenticatedHost: receiptlessAuthenticatedHost)
    }

    private static func authenticatedHostIdentity(
        advertised: WinkBridgeHostIdentity,
        listener: WinkBridgeListenerAttestation,
        signingIdentity: WinkBridgeHost.PeerSigningIdentity) -> WinkBridgeAuthenticatedHostIdentity?
    {
        guard let sourceCommit = signingIdentity.sourceCommit,
              advertised.sourceCommit == sourceCommit,
              let signingIdentifier = signingIdentity.bundleIdentifier,
              let teamIdentifier = signingIdentity.teamIdentifier
        else { return nil }
        return WinkBridgeAuthenticatedHostIdentity(
            processIdentifier: listener.host.processIdentifier,
            processStartIdentity: listener.host.processStartIdentity,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            codeSignatureHash: listener.host.codeSignatureHash,
            sourceCommit: sourceCommit,
            bundleShortVersion: advertised.bundleShortVersion,
            bundleVersion: advertised.bundleVersion)
    }

    private static func supportsStatelessClickVariants(_ handshake: WinkBridgeHandshakeResponse) -> Bool {
        let requiredOperations: Set<WinkBridgeOperation> = [.targetedClick, .exactWindowTargetedClick]
        return handshake.negotiatedVersion >= WinkBridgeConstants.statelessClickVariantVersion &&
            handshake.hostCapabilities?.contains(WinkBridgeHostCapability.statelessClickVariants) == true &&
            requiredOperations.isSubset(of: Set(handshake.supportedOperations)) &&
            requiredOperations.isSubset(of: Set(handshake.enabledOperations ?? handshake.supportedOperations))
    }

    private static func supportsProducerBoundSnapshotReferences(
        _ handshake: WinkBridgeHandshakeResponse) -> Bool
    {
        handshake.negotiatedVersion >= WinkBridgeConstants.producerBoundSnapshotReferencesVersion &&
            handshake.hostCapabilities?.contains(WinkBridgeHostCapability.attestedOperationReceipts) == true &&
            handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.producerBoundSnapshotReferences) == true &&
            handshake.supportedOperations.contains(.ownsSnapshot) &&
            (handshake.enabledOperations?.contains(.ownsSnapshot) ?? true)
    }

    private static func supportsTargetedClickAccessibilityValueDelivery(
        _ handshake: WinkBridgeHandshakeResponse) -> Bool
    {
        handshake.negotiatedVersion >= WinkBridgeConstants.targetedClickAccessibilityValueDeliveryVersion &&
            handshake.hostCapabilities?.contains(WinkBridgeHostCapability.attestedOperationReceipts) == true &&
            handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.targetedClickAccessibilityValueDelivery) == true &&
            handshake.supportedOperations.contains(.targetedClick) &&
            (handshake.enabledOperations?.contains(.targetedClick) ?? true)
    }

    private static func supportsCompositeTypeDelivery(_ handshake: WinkBridgeHandshakeResponse) -> Bool {
        let operations: Set<WinkBridgeOperation> = [
            .targetedTypeActions,
            .exactWindowTargetedTypeActions,
            .exactWindowPixelFocusType,
        ]
        let supported = Set(handshake.supportedOperations)
        let enabled = Set(handshake.enabledOperations ?? handshake.supportedOperations)
        return handshake.negotiatedVersion >= WinkBridgeConstants.compositeTypeDeliveryVersion &&
            handshake.hostCapabilities?.contains(WinkBridgeHostCapability.attestedOperationReceipts) == true &&
            handshake.hostCapabilities?.contains(WinkBridgeHostCapability.compositeTypeDelivery) == true &&
            !supported.isDisjoint(with: operations) &&
            !enabled.isDisjoint(with: operations)
    }

    private static func supportsAgentExecutionTrace(_ handshake: WinkBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= WinkBridgeConstants.agentExecutionTraceVersion &&
            handshake.hostCapabilities?.contains(WinkBridgeHostCapability.agentExecutionTrace) == true &&
            handshake.supportedOperations.contains(.agentExecutionTrace) &&
            (handshake.enabledOperations?.contains(.agentExecutionTrace) ?? true)
    }

    private static func supportsProcessGenerationObservation(_ handshake: WinkBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= WinkBridgeConstants.processGenerationObservationVersion &&
            handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.processGenerationObservation) == true &&
            handshake.supportedOperations.contains(.observeProcessGeneration) &&
            (handshake.enabledOperations?.contains(.observeProcessGeneration) ?? true)
    }

    private static func supportsCertificationProducerAttestation(
        _ handshake: WinkBridgeHandshakeResponse) -> Bool
    {
        handshake.negotiatedVersion >= WinkBridgeConstants.certificationProducerAttestationVersion &&
            handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.certificationProducerAttestation) == true &&
            handshake.supportedOperations.contains(.certificationProducerAttestation) &&
            (handshake.enabledOperations?.contains(.certificationProducerAttestation) ?? true)
    }

    private static func supportsSetValueResultTargetBinding(_ handshake: WinkBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= WinkBridgeConstants.setValueResultTargetBindingVersion &&
            handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.setValueResultTargetBinding) == true &&
            handshake.supportedOperations.contains(.setValue)
    }

    private static func supportsProcessGenerationBoundElementMutations(
        _ handshake: WinkBridgeHandshakeResponse) -> Bool
    {
        handshake.negotiatedVersion >=
            WinkBridgeConstants.processGenerationBoundElementMutationsVersion &&
            handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.processGenerationBoundElementMutations) == true
    }

    private static func supportsForegroundModifierClickSnapshotLease(
        _ handshake: WinkBridgeHandshakeResponse) -> Bool
    {
        handshake.negotiatedVersion >= WinkBridgeConstants.composedInputParityVersion &&
            handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.foregroundModifierClickSnapshotLease) == true &&
            handshake.supportedOperations.contains(.foregroundModifierClick) &&
            (handshake.enabledOperations?.contains(.foregroundModifierClick) ?? true)
    }

    private static func supportsNativeBrowserConnectionBinding(
        _ handshake: WinkBridgeHandshakeResponse) -> Bool
    {
        let operations: Set<WinkBridgeOperation> = [
            .browserStatus,
            .browserConnect,
            .browserDisconnect,
            .browserExecute,
        ]
        return handshake.negotiatedVersion >= WinkBridgeConstants.nativeBrowserConnectionBindingVersion &&
            handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.nativeBrowserConnectionBinding) == true &&
            operations.isSubset(of: Set(handshake.supportedOperations))
    }

    private static func supportsBrowserConnectionHandoff(
        _ handshake: WinkBridgeHandshakeResponse) -> Bool
    {
        let operations: Set<WinkBridgeOperation> = [
            .browserStatus,
            .browserConnect,
            .browserExecute,
            .browserSessionBootstrap,
            .browserSessionControl,
        ]
        return handshake.negotiatedVersion >= WinkBridgeConstants.browserConnectionHandoffVersion &&
            handshake.hostCapabilities?.contains(
                WinkBridgeHostCapability.browserConnectionHandoff) == true &&
            operations.isSubset(of: Set(handshake.supportedOperations)) &&
            operations.isSubset(of: Set(handshake.enabledOperations ?? handshake.supportedOperations))
    }

    private func installHandshakeCandidate(
        _ candidate: WinkBridgeClientHandshakeCandidate,
        inputs: WinkBridgeClientHandshakeInputs?,
        token: UInt64,
        replacingSessionID: UUID? = nil,
        allowLegacyReplacement: Bool = false) throws
    {
        try self.checkHandshakeToken(token)
        var preservesInstalledSuccessor = false
        if let replacingSessionID {
            if self.isExactInstalledSuccessor(candidate, replacingSessionID: replacingSessionID) {
                preservesInstalledSuccessor = true
            } else {
                guard self.operationSession?.attestation.sessionID == replacingSessionID else {
                    throw WinkBridgeClientOperationSessionError.superseded
                }
            }
            if !preservesInstalledSuccessor,
               candidate.response.negotiatedVersion >= WinkBridgeConstants.attestedOperationReceiptVersion
            {
                let predecessorListener = self.operationAttestation ?? self.operationSession?.listenerAttestation
                guard candidate.listenerAttestation == predecessorListener,
                      candidate.listenerLiveIdentity == self.operationSession?.listenerLiveIdentity,
                      candidate.sessionAttestation?.predecessorSessionID == replacingSessionID
                else {
                    throw WinkBridgeClientOperationSessionError.superseded
                }
            } else if !preservesInstalledSuccessor, !allowLegacyReplacement {
                throw WinkBridgeClientOperationSessionError.superseded
            }
        }
        self.actionProjectionEnabled = candidate.actionProjectionEnabled
        self.exactDialogInputExecutionEnabled = candidate.exactDialogInputExecutionEnabled
        self.exactDialogForceDismissExecutionEnabled = candidate.exactDialogForceDismissExecutionEnabled
        self.dialogInputFocusPolicyEnabled = candidate.dialogInputFocusPolicyEnabled
        self.exactFileDialogExecutionEnabled = candidate.exactFileDialogExecutionEnabled
        self.applicationMutationInventoryTransportEnabled =
            candidate.applicationMutationInventoryTransportEnabled
        self.windowMutationInventoryTransportEnabled = candidate.windowMutationInventoryTransportEnabled
        self.inputCapabilities = candidate.inputCapabilities
        self.operationAttestation = candidate.listenerAttestation
        self.installReceiptlessAuthenticatedHost(candidate.receiptlessAuthenticatedHost)
        if let listenerAttestation = candidate.listenerAttestation,
           let listenerLiveIdentity = candidate.listenerLiveIdentity,
           let sessionAttestation = candidate.sessionAttestation
        {
            if !preservesInstalledSuccessor {
                self.installOperationSessionState(
                    sessionAttestation,
                    listenerAttestation: listenerAttestation,
                    listenerLiveIdentity: listenerLiveIdentity,
                    hostBuild: candidate.response.build,
                    authenticatedHostIdentity: candidate.authenticatedHostIdentity)
            }
        } else {
            // A legacy negotiation cannot retire the server-side 1.29 session because the old host ignores
            // additive replacement fields. Retain its identity only for a later authenticated 1.29 handshake;
            // `operationAttestation == nil` keeps all legacy requests outside receipt carriage meanwhile.
            if replacingSessionID == nil || !allowLegacyReplacement {
                self.operationSession = nil
            }
            self.operationSessionInvalidated = false
        }
        self.hasSuccessfulHandshake = true
        self.finishHandshakeAttempt(token: token)
        if !preservesInstalledSuccessor {
            self.latestVerifiedOperationReceipt = nil
            self.latestVerifiedOperationReceiptBundle = nil
        }
        if let inputs {
            self.lastSuccessfulHandshakeInputs = inputs
        }
    }

    private func installReceiptlessAuthenticatedHost(_ host: WinkBridgeConnectedHostIdentity?) {
        self.receiptlessAuthenticationEpoch &+= 1
        if self.receiptlessAuthenticationEpoch == 0 {
            self.receiptlessAuthenticationEpoch = 1
        }
        self.receiptlessAuthenticatedHost = host
    }

    /// A signed rollover can win the response race with an explicit replacement handshake. If both carry the exact
    /// same successor, the handshake succeeded logically, but reinstalling it would reset its deterministic sequence
    /// and local claim budget. Preserve the already-live state instead.
    private func isExactInstalledSuccessor(
        _ candidate: WinkBridgeClientHandshakeCandidate,
        replacingSessionID: UUID) -> Bool
    {
        guard !self.operationSessionInvalidated,
              candidate.response.negotiatedVersion >= WinkBridgeConstants.attestedOperationReceiptVersion,
              let candidateListener = candidate.listenerAttestation,
              let candidateLiveIdentity = candidate.listenerLiveIdentity,
              let candidateSession = candidate.sessionAttestation,
              candidateSession.predecessorSessionID == replacingSessionID,
              let current = self.operationSession,
              current.listenerAttestation == candidateListener,
              current.listenerLiveIdentity == candidateLiveIdentity,
              current.attestation == candidateSession,
              self.operationAttestation == candidateListener
        else { return false }
        return true
    }

    @discardableResult
    private func installOperationSessionState(
        _ attestation: WinkBridgeOperationSessionAttestation,
        listenerAttestation: WinkBridgeListenerAttestation,
        listenerLiveIdentity: WinkBridgeLivePeerIdentity,
        hostBuild: String?,
        authenticatedHostIdentity: WinkBridgeAuthenticatedHostIdentity?) -> UInt64
    {
        self.operationSessionEpoch &+= 1
        if self.operationSessionEpoch == 0 {
            self.operationSessionEpoch = 1
        }
        let epoch = self.operationSessionEpoch
        self.operationSession = WinkBridgeClientOperationSession(
            epoch: epoch,
            listenerAttestation: listenerAttestation,
            listenerLiveIdentity: listenerLiveIdentity,
            hostBuild: hostBuild,
            authenticatedHostIdentity: authenticatedHostIdentity,
            attestation: attestation,
            nextSequence: .init(0),
            remainingClaimCount: attestation.remainingClaimCount)
        self.operationSessionInvalidated = false
        self.latestVerifiedOperationReceipt = nil
        self.latestVerifiedOperationReceiptBundle = nil
        return epoch
    }

    private func validateOperationSession(
        _ session: WinkBridgeOperationSessionAttestation,
        listenerAttestation: WinkBridgeListenerAttestation,
        replacingSessionID: UUID?) throws
    {
        try session.validateSignature(listenerAttestation: listenerAttestation)
        guard session.clientInstanceID == self.operationClientInstanceID,
              try session.client == (self.operationClientProcessIdentity()),
              session.predecessorSessionID == replacingSessionID
        else {
            throw WinkBridgeOperationReceiptError.operationSessionMismatch
        }
    }

    func operationClientProcessIdentity() throws -> WinkBridgeOperationProcessIdentity {
        let processIdentifier = getpid()
        guard let processStartIdentity = SystemIdentityResolver.processStartIdentity(processIdentifier) else {
            throw WinkBridgeErrorEnvelope(
                code: .internalError,
                message: "Could not establish the Bridge client's process-generation receipt")
        }
        guard let codeSignatureHash = WinkBridgeCodeSignatureIdentity.codeSignatureHash(
            processIdentifier: processIdentifier)
        else {
            throw WinkBridgeErrorEnvelope(
                code: .internalError,
                message: "Could not establish the Bridge client's code-signature receipt")
        }
        return WinkBridgeOperationProcessIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            codeSignatureHash: codeSignatureHash)
    }

    private func beginHandshake(supersedingRenewal: Bool) -> UInt64 {
        if supersedingRenewal {
            self.operationSessionRenewal?.task.cancel()
            self.operationSessionRenewal = nil
        }
        self.handshakeEpoch &+= 1
        if self.handshakeEpoch == 0 {
            self.handshakeEpoch = 1
        }
        self.activeHandshakeToken = self.handshakeEpoch
        return self.handshakeEpoch
    }

    private func finishHandshakeAttempt(token: UInt64) {
        if self.activeHandshakeToken == token {
            self.activeHandshakeToken = nil
        }
    }

    private func checkHandshakeToken(_ token: UInt64) throws {
        guard token == self.handshakeEpoch else {
            throw WinkBridgeClientOperationSessionError.superseded
        }
    }

    private func handshakeDeadline(overallTimeoutSec: TimeInterval?) throws -> Date? {
        guard let overallTimeoutSec else { return nil }
        guard overallTimeoutSec.isFinite, overallTimeoutSec > 0 else {
            throw POSIXError(.EINVAL)
        }
        return Date().addingTimeInterval(overallTimeoutSec)
    }

    private func remainingOverallHandshakeTimeout(deadline: Date?) throws -> TimeInterval? {
        guard let deadline else { return nil }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw POSIXError(.ETIMEDOUT) }
        return remaining
    }

    private nonisolated static func canRetryFreshHandshake(after error: any Error) -> Bool {
        guard let envelope = error as? WinkBridgeErrorEnvelope else { return false }
        return switch envelope.code {
        case .invalidRequest, .unauthorizedClient, .decodingFailed:
            true
        default:
            false
        }
    }

    private nonisolated static func operationSessionFailureRequiresColdHandshake(_ error: any Error) -> Bool {
        if let receiptError = error as? WinkBridgeOperationReceiptError,
           receiptError == .peerIdentityMismatch
        {
            return true
        }
        return self.canRetryFreshHandshake(after: error)
    }

    /// A newer public handshake cancels the shared renewal task without cancelling its waiters. Preserve actual caller
    /// cancellation, but report shared-task cancellation as session supersession so mutations remain retry-safe.
    private nonisolated static func normalizedOperationSessionRenewalError(_ error: any Error) -> any Error {
        guard error is CancellationError, !Task.isCancelled else { return error }
        return WinkBridgeClientOperationSessionError.superseded
    }

    private func remainingHandshakeTimeout(deadline: Date?) throws -> TimeInterval? {
        guard let deadline else { return nil }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw POSIXError(.ETIMEDOUT)
        }
        return min(self.requestTimeoutSec, remaining)
    }

    private nonisolated static func resolveTrustedHostTeamIDs(
        explicit: Set<String>?,
        socketPath: String) -> Set<String>?
    {
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        return WinkBridgeConstants.defaultTrustedHostTeamIDs(socketPath: socketPath)
    }

    private func effectiveHandshakeProtocolVersion(
        _ requested: WinkBridgeProtocolVersion) -> WinkBridgeProtocolVersion
    {
        guard requested >= WinkBridgeConstants.attestedOperationReceiptVersion,
              self.trustedHostTeamIDs == nil
        else { return requested }
        return WinkBridgeProtocolVersion(
            major: WinkBridgeConstants.attestedOperationReceiptVersion.major,
            minor: WinkBridgeConstants.attestedOperationReceiptVersion.minor - 1)
    }
}

public struct WinkBridgeOperationReceiptExportFailure: Equatable, Sendable {
    public let requestID: UUID
    public let directoryPath: String
    public let message: String
}

struct WinkBridgeClientOperationSessionReservation: Sendable {
    let epoch: UInt64
    let listenerAttestation: WinkBridgeListenerAttestation
    let listenerLiveIdentity: WinkBridgeLivePeerIdentity
    let hostBuild: String?
    let sessionAttestation: WinkBridgeOperationSessionAttestation
    let sequence: WinkBridgeOperationSessionSequence
    let requestID: UUID
    let clientIdentity: WinkBridgeOperationProcessIdentity
}

enum WinkBridgeClientOperationSessionError: Error, LocalizedError, Equatable {
    case handshakeRequired
    case unavailable
    case negotiationInProgress
    case renewalRequired(sessionID: UUID, epoch: UInt64)
    case superseded

    var errorDescription: String? {
        switch self {
        case .handshakeRequired:
            "Bridge requests require a successful protocol handshake"
        case .unavailable:
            "Bridge operation session is unavailable; complete a new handshake"
        case .negotiationInProgress:
            "Bridge handshake is still negotiating an operation session"
        case .renewalRequired:
            "Bridge operation session must roll over before another request"
        case .superseded:
            "Bridge operation session negotiation was superseded by a newer handshake"
        }
    }
}

private struct WinkBridgeClientOperationSession: Sendable {
    let epoch: UInt64
    let listenerAttestation: WinkBridgeListenerAttestation
    let listenerLiveIdentity: WinkBridgeLivePeerIdentity
    let hostBuild: String?
    let authenticatedHostIdentity: WinkBridgeAuthenticatedHostIdentity?
    let attestation: WinkBridgeOperationSessionAttestation
    var nextSequence: WinkBridgeOperationSessionSequence
    var remainingClaimCount: Int
}

private struct WinkBridgeClientHandshakeInputs: Sendable {
    let client: WinkBridgeClientIdentity
    let requestedHost: WinkBridgeHostKind?
    let protocolVersion: WinkBridgeProtocolVersion
    let allowsProtocolFallback: Bool
}

/// Client eligibility revoked together; server-session authority and retained non-input features stay separate.
private struct WinkBridgeClientInputCapabilities: Sendable {
    var exactWindowHeldPointerLifecycleEnabled = false
    var exactWindowDragEnabled = false
    var exactWindowHeldPointerTerminalCleanupEnabled = false
    var statelessClickVariantPayloadsEnabled = false
    var statelessClickVariantsEnabled = false
    var agentExecutionTraceEnabled = false
    var processGenerationObservationEnabled = false
    var certificationProducerAttestationEnabled = false
    var setValueResultTargetBindingEnabled = false
    var textSelectionEnabled = false
    var processGenerationBoundElementMutationsEnabled = false
    var foregroundModifierClickSnapshotLeaseEnabled = false
    var nativeBrowserConnectionBindingEnabled = false
    var browserConnectionHandoffEnabled = false
    var producerBoundSnapshotReferencesEnabled = false
    var scopedMenuBarActionsEnabled = false
    var targetedClickAccessibilityValueDeliveryEnabled = false
    var requestPinnedExactWindowScrollReceiptEnabled = false
    var backgroundCoordinateScrollEnabled = false
    var compositeTypeDeliveryEnabled = false
    var clipboardGuardedExactWindowHotkeysEnabled = false
    var preparedClipboardGuardedExactWindowHotkeysEnabled = false
    var desktopObservationInlinePixelsEnabled = false
    var desktopObservationFreshAccessibilityTreeEnabled = false
}

private struct WinkBridgeClientHandshakeCandidate: Sendable {
    let response: WinkBridgeHandshakeResponse
    let actionProjectionEnabled: Bool
    let exactDialogInputExecutionEnabled: Bool
    let exactDialogForceDismissExecutionEnabled: Bool
    let dialogInputFocusPolicyEnabled: Bool
    let exactFileDialogExecutionEnabled: Bool
    let applicationMutationInventoryTransportEnabled: Bool
    let windowMutationInventoryTransportEnabled: Bool
    let inputCapabilities: WinkBridgeClientInputCapabilities
    let listenerAttestation: WinkBridgeListenerAttestation?
    let listenerLiveIdentity: WinkBridgeLivePeerIdentity?
    let sessionAttestation: WinkBridgeOperationSessionAttestation?
    let authenticatedHostIdentity: WinkBridgeAuthenticatedHostIdentity?
    let receiptlessAuthenticatedHost: WinkBridgeConnectedHostIdentity?
}

struct WinkBridgeReceiptlessHostReservation: Sendable {
    let epoch: UInt64
    let host: WinkBridgeConnectedHostIdentity
}

private struct WinkBridgeClientOperationSessionRenewal: Sendable {
    let replacingSessionID: UUID
    let predecessorEpoch: UInt64
    let token: UInt64
    let task: Task<WinkBridgeClientHandshakeCandidate, any Error>
}

private final class WinkBridgeClientOperationSessionRenewalWaiter: @unchecked Sendable {
    typealias RenewalResult = Result<WinkBridgeClientHandshakeCandidate, any Error>

    private let lock = NSLock()
    private var continuation: CheckedContinuation<WinkBridgeClientHandshakeCandidate, any Error>?
    private var result: RenewalResult?

    func install(_ continuation: CheckedContinuation<WinkBridgeClientHandshakeCandidate, any Error>) {
        self.lock.lock()
        if let result = self.result {
            self.lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        self.lock.unlock()
    }

    func finish(_ result: RenewalResult) {
        self.lock.lock()
        guard self.result == nil else {
            self.lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(with: result)
    }
}
