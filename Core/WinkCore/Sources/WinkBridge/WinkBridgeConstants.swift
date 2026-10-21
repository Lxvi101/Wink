import Foundation

public enum WinkBridgeConstants {
    public static let socketName = "bridge.sock"
    public static let cliBundleIdentifier = "boo.wink.wink"
    public static let certificationControllerBundleIdentifier = "boo.wink.wink-certification-controller"
    public static let guiClientBundleIdentifiers: Set<String> = [
        WinkBridgeConstants.cliBundleIdentifier,
        "boo.wink.mac",
        WinkBridgeConstants.certificationControllerBundleIdentifier,
    ]

    /// Release identities accepted during the OpenClaw Foundation signing migration.
    /// Keep the legacy team while standalone CLIs must interoperate with pre-3.8 GUI hosts.
    public static let trustedReleaseTeamIDs: Set<String> = ["Y5PE65HELJ", "FWJYW4S8P8"]

    /// Socket hosted by Wink.app (primary host).
    public static var winkSocketPath: String {
        self.applicationSupportSocketPath(appDirectoryName: "Wink", socketName: self.socketName)
    }

    /// Socket hosted by the reusable on-demand or manually started daemon.
    public static var daemonSocketPath: String {
        self.applicationSupportSocketPath(appDirectoryName: "Wink", socketName: "daemon.sock")
    }

    /// Socket hosted by Claude.app (fallback host; piggyback on Claude Desktop TCC grants).
    public static var claudeSocketPath: String {
        self.applicationSupportSocketPath(appDirectoryName: "Claude", socketName: self.socketName)
    }

    /// Canonical socket hosted by OpenClaw.app.
    public static var openClawSocketPath: String {
        self.applicationSupportSocketPath(appDirectoryName: "OpenClaw", socketName: self.socketName)
    }

    /// Socket hosted by Clawdbot.app (fallback host).
    public static var clawdbotSocketPath: String {
        self.applicationSupportSocketPath(appDirectoryName: "clawdbot", socketName: self.socketName)
    }

    /// Default host-signing policy for sockets owned by bundled Wink runtimes.
    ///
    /// Arbitrary socket paths deliberately return `nil`: protocol 1.29 callers must name the
    /// teams they trust instead of treating possession of a per-user filesystem path as host
    /// authentication.
    public static func defaultTrustedHostTeamIDs(socketPath: String) -> Set<String>? {
        let standardized = NSString(string: socketPath).standardizingPath
        let exactPaths = [
            self.winkSocketPath,
            self.daemonSocketPath,
            self.claudeSocketPath,
            self.openClawSocketPath,
            self.clawdbotSocketPath,
        ].map { NSString(string: $0).standardizingPath }
        if exactPaths.contains(standardized) {
            return self.trustedReleaseTeamIDs
        }

        let url = URL(fileURLWithPath: standardized)
        let daemonDirectory = URL(fileURLWithPath: self.daemonSocketPath)
            .deletingLastPathComponent().standardizedFileURL.path
        let filename = url.lastPathComponent
        let prefix = "daemon-"
        let suffix = ".sock"
        guard url.deletingLastPathComponent().standardizedFileURL.path == daemonDirectory,
              filename.hasPrefix(prefix),
              filename.hasSuffix(suffix)
        else { return nil }
        let hashStart = filename.index(filename.startIndex, offsetBy: prefix.count)
        let hashEnd = filename.index(filename.endIndex, offsetBy: -suffix.count)
        let hash = filename[hashStart..<hashEnd]
        guard hash.count == 16,
              hash.allSatisfy(\.isHexDigit)
        else { return nil }
        return self.trustedReleaseTeamIDs
    }

    /// Current protocol version supported by this build.
    public static let protocolVersion = WinkBridgeProtocolVersion(major: 1, minor: 43)

    /// Same-version clients must also offer the raw capability before receiving the new preparation operation.
    public static let scopedMenuBarActionsVersion = WinkBridgeProtocolVersion(major: 1, minor: 43)

    public static let backgroundCoordinateScrollVersion = WinkBridgeProtocolVersion(major: 1, minor: 43)

    /// Additive, capability-gated file execution; legacy file payloads retain their existing contract.
    public static let exactFileDialogExecutionVersion = WinkBridgeProtocolVersion(major: 1, minor: 43)

    public static let textSelectionVersion = WinkBridgeProtocolVersion(major: 1, minor: 42)

    /// Explicit target-only preparation before a clipboard-guarded exact-window paste.
    public static let preparedClipboardGuardedExactWindowHotkeyVersion = WinkBridgeProtocolVersion(
        major: 1,
        minor: 41)

    /// First protocol that fences exact-window paste with the caller's retained clipboard write claim.
    public static let clipboardGuardedExactWindowHotkeyVersion = WinkBridgeProtocolVersion(major: 1, minor: 40)

    /// First protocol with a bounded exact-window drag owned by the held-pointer lifecycle.
    public static let exactWindowDragVersion = WinkBridgeProtocolVersion(major: 1, minor: 39)

    /// First protocol with one-shot, receipt-bound foreground-connect handoff to a caller-scoped browser session.
    public static let browserConnectionHandoffVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 38)

    /// First protocol that can attest one exact Chrome bundle, process generation, listener, and DevTools identity.
    public static let nativeBrowserConnectionBindingVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 34)

    /// First protocol that can negotiate producer-bound snapshot references without exposing a
    /// new operation to already-shipped 1.34 clients that did not offer the raw capability.
    public static let producerBoundSnapshotReferencesVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 34)

    /// First protocol that can explicitly negotiate and enforce the AXFocused value-delivery policy for clicks.
    public static let targetedClickAccessibilityValueDeliveryVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 34)

    /// First protocol whose background scroll request carries a complete exact-window receipt that
    /// is pinned through execution and every signed result, including retry-unsafe failures.
    public static let requestPinnedExactWindowScrollReceiptVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 35)

    /// First protocol whose process- and exact-window targeted type results distinguish direct
    /// AXValue text/key/clear mutations from keyboard events and admit their composite delivery receipt.
    public static let compositeTypeDeliveryVersion = WinkBridgeProtocolVersion(major: 1, minor: 36)

    /// First protocol where a distinct host capability proves element mutations bind their
    /// snapshot receipt, resolved AX element, outcome, and target to one process generation.
    /// The raw capability distinguishes fixed hosts from shipped and reserved pre-1.37 hosts.
    public static let processGenerationBoundElementMutationsVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 37)

    /// First protocol with host-atomic exact-window pixel-focus typing and modifier-click payloads.
    public static let composedInputParityVersion = WinkBridgeProtocolVersion(major: 1, minor: 33)

    /// First protocol with a receipt-required, host-derived exact process-generation observation.
    public static let processGenerationObservationVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 32)

    /// First protocol with receipt-bound, host-authenticated certification producer evidence.
    public static let certificationProducerAttestationVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 32)

    /// First protocol whose set-value result preserves the exact opaque request target so its
    /// signed response can be bound to the request without post-dispatch ambiguity.
    public static let setValueResultTargetBindingVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 32)

    /// First protocol whose Bridge can launch the exact authenticated CLI peer as a suspended
    /// background Agent and return one listener-signed terminal execution trace.
    public static let agentExecutionTraceVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 31)

    /// First protocol that transports mutation-planner inventories with explicit completeness evidence.
    public static let plannerInventoryTransportVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 30)

    /// First protocol with owner-scoped exact-window held-pointer lifecycles.
    public static let exactWindowHeldPointerLifecycleVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 30)

    /// First protocol whose click payload can carry stateless middle- and triple-click variants.
    public static let statelessClickVariantVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 30)

    /// First protocol with listener-bound, signed per-operation receipts.
    public static let attestedOperationReceiptVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 29)

    /// First protocol with atomic host-side execution of an exact dialog input request.
    public static let exactDialogInputExecutionVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 27)

    /// First protocol with selector-preserving, host-atomic forced dialog dismissal.
    public static let exactForcedDialogDismissExecutionVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 28)

    /// First protocol whose legacy current-dialog input payload carries an explicit focus policy.
    public static let dialogInputFocusPolicyVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 28)

    /// First protocol with published snapshots that remain explicit-reference-only.
    public static let explicitSnapshotPublicationVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 26)

    /// First protocol whose browser connection is probed and pinned to one exact Chrome identity.
    public static let browserConnectionReceiptVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 26)

    /// First protocol with host-retained, one-shot exact dialog/button action receipts.
    public static let receiptPinnedDialogActionVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 25)

    /// First protocol with host-owned, fail-closed leases for snapshot-backed mutations.
    public static let snapshotMutationLeaseVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 24)

    /// First protocol with explicit per-request canonical desktop-action outcome carriage.
    public static let desktopActionOutcomeProjectionVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 23)

    /// First protocol that carries process-generation receipts with process-targeted typing and clicks.
    public static let processGenerationPinnedInteractionVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 22)

    /// First protocol whose desktop-observation payload and response preserve exact-window ROI
    /// requests, cropped viewport metadata, and snapshot coordinate context end to end.
    public static let exactWindowROIObservationVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 21)

    /// First protocol with one host-owned transaction for an observation snapshot's raster,
    /// element map, and optional annotation.
    public static let atomicObservationSnapshotPublicationVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 21)

    /// First protocol that carries an application process-generation receipt with quit requests.
    public static let processGenerationPinnedApplicationQuitVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 16)

    /// First protocol that signs caller-pinned application hide requests and results.
    public static let processGenerationPinnedApplicationHideVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 29)

    /// First protocol that carries a process-generation receipt with targeted hotkey requests.
    public static let processGenerationPinnedHotkeyVersion =
        WinkBridgeProtocolVersion(major: 1, minor: 19)

    /// Oldest protocol version this build can serve without changing request semantics.
    public static let minimumProtocolVersion = WinkBridgeProtocolVersion(major: 1, minor: 0)

    /// Compatible protocol range for negotiation. Update when introducing breaking changes.
    public static let supportedProtocolRange: ClosedRange<WinkBridgeProtocolVersion> =
        minimumProtocolVersion...protocolVersion

    /// Default deadline for one Bridge request or response.
    public static let defaultRequestTimeoutSeconds: TimeInterval = 10

    /// Build identifier advertised during handshake (falls back to "dev").
    public static var buildIdentifier: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleVersion"] as? String
        let short = info?["CFBundleShortVersionString"] as? String
        switch (short, version) {
        case let (short?, version?):
            return "\(short) (\(version))"
        case let (nil, version?):
            return version
        default:
            return "dev"
        }
    }

    private static func applicationSupportSocketPath(appDirectoryName: String, socketName: String) -> String {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = baseDirectory.appendingPathComponent(appDirectoryName, isDirectory: true)
        return directory.appendingPathComponent(socketName, isDirectory: false).path
    }
}

extension JSONEncoder {
    public static func winkBridgeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Keep legacy 1.0–1.8 date fields wire-compatible. Ordering-sensitive 1.9 fields use
        // model-specific numeric reference-date encoding so they retain subsecond precision.
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static func winkBridgeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = WinkBridgeDateCoding.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid Wink Bridge ISO-8601 date: \(value)")
            }
            return date
        }
        return decoder
    }
}

private enum WinkBridgeDateCoding {
    static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        guard let decimalIndex = value.firstIndex(of: ".") else {
            return formatter.date(from: value)
        }
        let fractionalStart = value.index(after: decimalIndex)
        let fractionalEnd = value[fractionalStart...].firstIndex(where: { !$0.isNumber }) ?? value.endIndex
        let fractionalDigits = value[fractionalStart..<fractionalEnd]
        guard !fractionalDigits.isEmpty,
              let fraction = Double("0.\(fractionalDigits)")
        else {
            return nil
        }

        let wholeSecondsValue = String(value[..<decimalIndex] + value[fractionalEnd...])
        guard let wholeSeconds = formatter.date(from: wholeSecondsValue) else {
            return nil
        }
        return wholeSeconds.addingTimeInterval(fraction)
    }
}
