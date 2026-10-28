import Foundation

public enum FeedbackCategory: String, Codable, Sendable, CaseIterable {
    case bug
    case missingCapability = "missing_capability"
    case featureRequest = "feature_request"
    case performance
    case documentation
    case usability
    case unexpectedBehavior = "unexpected_behavior"
}

public enum FeedbackSeverity: String, Codable, Sendable, CaseIterable {
    case low, medium, high, critical

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// What an agent sends to feedback_submit.
public struct FeedbackSubmission: Codable, Sendable {
    public var category: FeedbackCategory
    public var severity: FeedbackSeverity?
    public var summary: String
    public var expected: String?
    public var actual: String?
    public var wish: String?
    public var tool: String?
    public var errorCode: String?
    public var workflowId: String?
    public var runId: String?
    public var diagnosticId: String?
    public var reproSteps: [String]?
    public var attachRecentDiagnostics: Bool?
    public var client: String?

    public init(category: FeedbackCategory, summary: String) {
        self.category = category
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case category, severity, summary, expected, actual, wish, tool, client
        case errorCode = "error_code"
        case workflowId = "workflow_id"
        case runId = "run_id"
        case diagnosticId = "diagnostic_id"
        case reproSteps = "repro_steps"
        case attachRecentDiagnostics = "attach_recent_diagnostics"
    }
}

public struct FeedbackEnvironment: Codable, Equatable, Sendable {
    public var component: String
    public var version: String
    public var os: String
    public var arch: String

    public init(component: String, version: String) {
        self.component = component
        self.version = version
        self.os = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        self.arch = "arm64"
        #else
        self.arch = "x86_64"
        #endif
    }
}

public struct DiagnosticEntry: Codable, Equatable, Sendable {
    public var id: String
    public var time: String
    public var tool: String
    public var app: String?
    public var ok: Bool
    public var code: String?
    public var elapsedMs: Int
    public var message: String?

    enum CodingKeys: String, CodingKey {
        case id, time, tool, app, ok, code, message
        case elapsedMs = "elapsed_ms"
    }
}

public struct FeedbackReport: Codable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var fingerprint: String
    public var createdAt: String
    public var updatedAt: String
    public var occurrences: Int
    public var category: FeedbackCategory
    public var severity: FeedbackSeverity
    public var summary: String
    public var expected: String?
    public var actual: String?
    public var wish: String?
    public var tool: String?
    public var errorCode: String?
    public var workflowId: String?
    public var runId: String?
    public var diagnosticId: String?
    /// Up to five distinct reproductions, newest last.
    public var reproductions: [[String]]
    public var clients: [String]
    public var environment: FeedbackEnvironment
    public var diagnostics: [DiagnosticEntry]?

    enum CodingKeys: String, CodingKey {
        case id, fingerprint, occurrences, category, severity, summary, expected, actual, wish, tool, reproductions,
             clients, environment, diagnostics
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case errorCode = "error_code"
        case workflowId = "workflow_id"
        case runId = "run_id"
        case diagnosticId = "diagnostic_id"
    }
}

public struct FeedbackSubmitResult: Codable, Sendable {
    public var id: String
    /// "created" or "merged" (an identical report already existed; its count went up).
    public var status: String
    public var occurrences: Int
    public var stored: String

    enum CodingKeys: String, CodingKey { case id, status, occurrences, stored }
}

/// Local-only store for agent feedback. Nothing is uploaded; export is an explicit, separate step.
///
///     <root>/<report id>.json   0600, redacted, size-capped; 90-day / 500-report retention
public final class FeedbackStore: @unchecked Sendable {
    public let root: URL
    public var retentionDays = 90
    public var maxReports = 500
    public var rateLimit = (count: 20, seconds: 600.0)
    public var now: () -> Date = Date.init
    private let lock = NSLock()
    private var recentSubmissions: [Date] = []

    public static let fieldLimit = 2000
    public static let summaryLimit = 300

    public init(root: URL) {
        self.root = root
    }

    public static func defaultStore() -> FeedbackStore {
        FeedbackStore(root: PrivateFiles.configRoot().appendingPathComponent("feedback", isDirectory: true))
    }

    public func submit(_ s: FeedbackSubmission, environment: FeedbackEnvironment,
                       diagnostics: [DiagnosticEntry] = []) throws -> FeedbackSubmitResult {
        self.lock.lock()
        defer { self.lock.unlock() }
        let summary = Redactor.sanitize(s.summary.trimmingCharacters(in: .whitespacesAndNewlines), limit: Self.summaryLimit)
        guard summary.count >= 8 else {
            throw WorkflowError(.invalidArgument, "summary must describe the problem (at least 8 characters)")
        }
        let now = self.now()
        self.recentSubmissions = self.recentSubmissions.filter { now.timeIntervalSince($0) < self.rateLimit.seconds }
        guard self.recentSubmissions.count < self.rateLimit.count else {
            throw WorkflowError(.rateLimited, "more than \(self.rateLimit.count) reports in \(Int(self.rateLimit.seconds / 60)) minutes")
        }
        self.recentSubmissions.append(now)
        self.applyRetention()

        func clean(_ text: String?) -> String? {
            text.map { Redactor.sanitize($0, limit: Self.fieldLimit) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let repro = (s.reproSteps ?? []).prefix(20).map { Redactor.sanitize($0, limit: 300) }
        let tool = clean(s.tool).map { Redactor.clip($0, 64) }
        let code = clean(s.errorCode).map { Redactor.clip($0, 64) }
        let fingerprint = IDs.fingerprint([s.category.rawValue, tool ?? "", code ?? "", Self.normalize(summary)].joined(separator: "|"))
        let stamp = WorkflowClock.now()
        let client = clean(s.client).map { Redactor.clip($0, 40) }

        if var existing = self.all().first(where: { $0.fingerprint == fingerprint }) {
            existing.occurrences += 1
            existing.updatedAt = stamp
            if let severity = s.severity, severity.rank > existing.severity.rank { existing.severity = severity }
            if !repro.isEmpty, !existing.reproductions.contains(repro) {
                existing.reproductions = Array((existing.reproductions + [repro]).suffix(5))
            }
            if let client, !existing.clients.contains(client), existing.clients.count < 20 { existing.clients.append(client) }
            existing.wish = existing.wish ?? clean(s.wish)
            existing.expected = existing.expected ?? clean(s.expected)
            existing.actual = existing.actual ?? clean(s.actual)
            existing.environment = environment
            if s.attachRecentDiagnostics == true, !diagnostics.isEmpty { existing.diagnostics = diagnostics }
            try self.write(existing)
            return FeedbackSubmitResult(id: existing.id, status: "merged", occurrences: existing.occurrences, stored: "local")
        }

        let report = FeedbackReport(
            schemaVersion: 1, id: IDs.make("fb"), fingerprint: fingerprint, createdAt: stamp, updatedAt: stamp, occurrences: 1,
            category: s.category, severity: s.severity ?? .medium, summary: summary, expected: clean(s.expected),
            actual: clean(s.actual), wish: clean(s.wish), tool: tool, errorCode: code,
            workflowId: clean(s.workflowId).map { Redactor.clip($0, 64) }, runId: clean(s.runId).map { Redactor.clip($0, 64) },
            diagnosticId: clean(s.diagnosticId).map { Redactor.clip($0, 64) }, reproductions: repro.isEmpty ? [] : [repro],
            clients: client.map { [$0] } ?? [], environment: environment,
            diagnostics: s.attachRecentDiagnostics == true && !diagnostics.isEmpty ? diagnostics : nil)
        try self.write(report)
        return FeedbackSubmitResult(id: report.id, status: "created", occurrences: 1, stored: "local")
    }

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased().unicodeScalars.map { CharacterSet.decimalDigits.contains($0) ? "#" : String($0) }.joined()
        return lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "#" }).joined(separator: " ")
    }

    private func write(_ report: FeedbackReport) throws {
        try PrivateFiles.ensureDirectory(self.root)
        try PrivateFiles.write(WorkflowJSON.encode(report), to: self.root.appendingPathComponent("\(report.id).json"))
    }

    public func all() -> [FeedbackReport] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: self.root.path)) ?? []
        return names.filter { $0.hasPrefix("fb_") && $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? PrivateFiles.read(self.root.appendingPathComponent(name), limit: 256 * 1024) else { return nil }
            return try? WorkflowJSON.decode(FeedbackReport.self, from: data)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func get(_ id: String) throws -> FeedbackReport {
        let id = try PrivateFiles.checkedID(id, kind: "feedback")
        let data = try PrivateFiles.read(self.root.appendingPathComponent("\(id).json"), limit: 256 * 1024)
        return try WorkflowJSON.decode(FeedbackReport.self, from: data)
    }

    public func delete(_ id: String) throws {
        let id = try PrivateFiles.checkedID(id, kind: "feedback")
        try PrivateFiles.remove(self.root.appendingPathComponent("\(id).json"))
    }

    /// Markdown (for an issue tracker, after the user approves sharing it) or a JSON array.
    public func export(format: String) -> String {
        let reports = self.all()
        if format == "json" {
            return (try? WorkflowJSON.encode(reports)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        var out = "# Wink agent feedback (\(reports.count) reports)\n"
        for r in reports {
            out += "\n## \(r.summary)\n\n"
            out += "- id: `\(r.id)` · \(r.category.rawValue) · \(r.severity.rawValue) · seen \(r.occurrences)x · last \(r.updatedAt)\n"
            if let tool = r.tool { out += "- tool: `\(tool)`\(r.errorCode.map { " · code `\($0)`" } ?? "")\n" }
            out += "- environment: \(r.environment.component) \(r.environment.version), \(r.environment.os), \(r.environment.arch)\n"
            if let e = r.expected { out += "- expected: \(e)\n" }
            if let a = r.actual { out += "- actual: \(a)\n" }
            if let w = r.wish { out += "- wish: \(w)\n" }
            for (i, steps) in r.reproductions.enumerated() {
                out += "- reproduction \(i + 1):\n" + steps.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n") + "\n"
            }
        }
        return out
    }

    func applyRetention() {
        let reports = self.all()
        let cutoff = self.now().addingTimeInterval(-Double(self.retentionDays) * 86400)
        for r in reports where (WorkflowClock.parse(r.updatedAt) ?? .distantPast) < cutoff {
            try? self.delete(r.id)
        }
        let fresh = reports.filter { (WorkflowClock.parse($0.updatedAt) ?? .distantPast) >= cutoff }
        for r in fresh.dropFirst(self.maxReports - 1) { try? self.delete(r.id) }
    }
}

/// Ring buffer of recent tool outcomes (no UI content), attachable to feedback.
public final class DiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [DiagnosticEntry] = []
    private let capacity: Int

    public init(capacity: Int = 50) {
        self.capacity = capacity
    }

    @discardableResult
    public func record(tool: String, app: String?, ok: Bool, code: String? = nil, elapsedMs: Int,
                       message: String? = nil) -> String {
        let id = IDs.make("diag")
        let entry = DiagnosticEntry(id: id, time: WorkflowClock.now(), tool: tool, app: app.map { Redactor.clip($0, 80) },
                                    ok: ok, code: code, elapsedMs: elapsedMs,
                                    message: ok ? nil : message.map { Redactor.sanitize($0, limit: 160) })
        self.lock.lock()
        self.entries.append(entry)
        if self.entries.count > self.capacity { self.entries.removeFirst(self.entries.count - self.capacity) }
        self.lock.unlock()
        return id
    }

    public func recent(_ n: Int = 10) -> [DiagnosticEntry] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return Array(self.entries.suffix(n))
    }
}
