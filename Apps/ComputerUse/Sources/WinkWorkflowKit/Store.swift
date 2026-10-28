import Foundation

/// Private on-disk storage: directories 0700, files 0600, atomic replace, no symlinks, size caps,
/// ids restricted to a safe alphabet so a name can never escape its directory.
public enum PrivateFiles {
    public static let maxReadBytes = 2 * 1024 * 1024

    /// `$WINK_WORKFLOW_HOME`, else `$PEEKABOO_CONFIG_DIR`, else `~/.peekaboo` (Wink's config directory).
    public static func configRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["WINK_WORKFLOW_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let config = environment["PEEKABOO_CONFIG_DIR"], !config.isEmpty {
            return URL(fileURLWithPath: (config as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".peekaboo")
    }

    public static func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue, !self.isSymlink(url) else {
                throw WorkflowError(.storage, "\(url.lastPathComponent) is not a private directory")
            }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        chmod(url.path, 0o700)
    }

    static func isSymlink(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Writes via a 0600 temp file in the same directory, then rename(2): readers never see partial files.
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try self.ensureDirectory(dir)
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw WorkflowError(.storage, "cannot create \(tmp.lastPathComponent): errno \(errno)") }
        let ok = data.withUnsafeBytes { buf -> Bool in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress!.advanced(by: offset), buf.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard ok, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw WorkflowError(.storage, "cannot write \(url.lastPathComponent)")
        }
    }

    public static func read(_ url: URL, limit: Int = maxReadBytes) throws -> Data {
        guard !self.isSymlink(url) else { throw WorkflowError(.storage, "\(url.lastPathComponent) is a symlink") }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let attrs, attrs[.type] as? FileAttributeType == .typeRegular else {
            throw WorkflowError(.notFound, "\(url.lastPathComponent) not found")
        }
        if let size = attrs[.size] as? Int, size > limit {
            throw WorkflowError(.schemaInvalid, "\(url.lastPathComponent) is larger than \(limit / 1024) KB")
        }
        return try Data(contentsOf: url)
    }

    public static func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) || self.isSymlink(url) else {
            throw WorkflowError(.notFound, "\(url.lastPathComponent) not found")
        }
        try FileManager.default.removeItem(at: url)
    }

    static func checkedID(_ id: String, kind: String) throws -> String {
        guard IDs.isSafe(id) else { throw WorkflowError(.invalidArgument, "invalid \(kind) id '\(Redactor.clip(id, 40))'") }
        return id
    }
}

public struct WorkflowSummary: Codable, Sendable {
    public var id: String
    public var name: String
    public var revision: Int
    public var status: WorkflowStatus
    public var effect: WorkflowEffect
    public var bundleIds: [String]
    public var inputs: [String]
    public var steps: Int
    public var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, revision, status, effect, inputs, steps
        case bundleIds = "bundle_ids"
        case updatedAt = "updated_at"
    }
}

/// Versioned workflow library + recordings + run records.
///
///     <root>/definitions/<id>/r<revision>.json   every revision, newest = highest
///     <root>/recordings/<recording id>.json
///     <root>/runs/<run id>.json                  sanitized results, newest 200 kept
public final class WorkflowStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    public static let maxRuns = 200
    public static let maxRecordings = 100

    public init(root: URL) {
        self.root = root
    }

    public static func defaultStore() -> WorkflowStore {
        WorkflowStore(root: PrivateFiles.configRoot().appendingPathComponent("workflows", isDirectory: true))
    }

    var definitions: URL { self.root.appendingPathComponent("definitions", isDirectory: true) }
    var recordings: URL { self.root.appendingPathComponent("recordings", isDirectory: true) }
    var runs: URL { self.root.appendingPathComponent("runs", isDirectory: true) }

    // MARK: Workflows

    public func revisions(of id: String) throws -> [Int] {
        let dir = self.definitions.appendingPathComponent(try PrivateFiles.checkedID(id, kind: "workflow"))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix("r"), name.hasSuffix(".json") else { return nil }
            return Int(name.dropFirst().dropLast(5))
        }.sorted()
    }

    public func load(_ id: String, revision: Int? = nil) throws -> Workflow {
        let id = try PrivateFiles.checkedID(id, kind: "workflow")
        guard let rev = try revision ?? self.revisions(of: id).last else {
            throw WorkflowError(.notFound, "no workflow '\(id)'")
        }
        let url = self.definitions.appendingPathComponent(id).appendingPathComponent("r\(rev).json")
        let wf = try WorkflowValidator.decode(PrivateFiles.read(url, limit: WorkflowValidator.maxFileBytes))
        guard wf.id == id, wf.revision == rev else {
            throw WorkflowError(.schemaInvalid, "\(id) r\(rev) does not match its file location")
        }
        return wf
    }

    /// Saves a new revision. Scope changes (apps, effect, foreground, new action kinds) against the previous
    /// revision need `allowScopeChange`; any content change resets the status to draft.
    @discardableResult
    public func save(_ workflow: Workflow, expectedRevision: Int? = nil, allowScopeChange: Bool = false) throws -> Workflow {
        self.lock.lock()
        defer { self.lock.unlock() }
        var wf = workflow
        let id = try PrivateFiles.checkedID(wf.id, kind: "workflow")
        let existing = try self.revisions(of: id)
        let latest = existing.last ?? 0
        if let expectedRevision, expectedRevision != latest {
            throw WorkflowError(.revisionConflict, "expected revision \(expectedRevision) but the latest is \(latest)")
        }
        let now = WorkflowClock.now()
        if latest > 0 {
            let previous = try self.load(id, revision: latest)
            var comparable = wf
            comparable.revision = previous.revision
            comparable.status = previous.status
            comparable.createdAt = previous.createdAt
            comparable.updatedAt = previous.updatedAt
            if comparable == previous { return previous } // nothing changed
            if !allowScopeChange, let why = Self.scopeChange(from: previous, to: wf) {
                throw WorkflowError(.scopeChangeNeedsApproval, why)
            }
            wf.createdAt = previous.createdAt
            if wf.status != .disabled { wf.status = .draft }
        } else {
            wf.createdAt = wf.createdAt ?? now
            if wf.status != .disabled { wf.status = .draft }
        }
        wf.revision = latest + 1
        wf.updatedAt = now
        let report = WorkflowValidator.validate(wf)
        // Drafts may be saved incomplete so an agent can iterate, but never with unsafe structure.
        if let blocking = report.errors.first(where: { $0.code == .permissionDenied || $0.path == "id" }) {
            throw WorkflowError(blocking.code, "\(blocking.path): \(blocking.message)")
        }
        let url = self.definitions.appendingPathComponent(id).appendingPathComponent("r\(wf.revision).json")
        try PrivateFiles.write(WorkflowJSON.encode(wf), to: url)
        return wf
    }

    /// Status changes rewrite the head revision in place (content unchanged).
    @discardableResult
    public func setStatus(_ id: String, _ status: WorkflowStatus) throws -> Workflow {
        self.lock.lock()
        defer { self.lock.unlock() }
        var wf = try self.load(id)
        if status == .validated || status == .published {
            let report = WorkflowValidator.validate(wf)
            guard report.valid else {
                throw WorkflowError(.schemaInvalid, report.errors.prefix(3).map { "\($0.path): \($0.message)" }.joined(separator: "; "))
            }
            if status == .published, !wf.hasVerification {
                throw WorkflowError(.schemaInvalid, "publishing needs at least one wait_for/assert step or postcondition")
            }
        }
        wf.status = status
        wf.updatedAt = WorkflowClock.now()
        let url = self.definitions.appendingPathComponent(wf.id).appendingPathComponent("r\(wf.revision).json")
        try PrivateFiles.write(WorkflowJSON.encode(wf), to: url)
        return wf
    }

    /// Copies an old revision forward as a new draft revision.
    public func rollback(_ id: String, to revision: Int) throws -> Workflow {
        var old = try self.load(id, revision: revision)
        old.provenance = Provenance(source: "rollback", recordingId: old.provenance?.recordingId,
                                    notes: "rolled back to r\(revision)")
        return try self.save(old, allowScopeChange: true)
    }

    public func delete(_ id: String) throws {
        let id = try PrivateFiles.checkedID(id, kind: "workflow")
        try PrivateFiles.remove(self.definitions.appendingPathComponent(id))
    }

    public func list() -> [WorkflowSummary] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: self.definitions.path)) ?? []
        return ids.filter(IDs.isSafe).sorted().compactMap { id in
            guard let wf = try? self.load(id) else { return nil }
            return WorkflowSummary(id: wf.id, name: wf.name, revision: wf.revision, status: wf.status, effect: wf.effect,
                                   bundleIds: wf.target.bundleIds, inputs: wf.inputs.keys.sorted(), steps: wf.steps.count,
                                   updatedAt: wf.updatedAt)
        }
    }

    static func scopeChange(from old: Workflow, to new: Workflow) -> String? {
        if !Set(new.target.bundleIds).isSubset(of: Set(old.target.bundleIds)) {
            return "target apps changed from \(old.target.bundleIds) to \(new.target.bundleIds)"
        }
        if new.effect.rank > old.effect.rank { return "effect widened from \(old.effect.rawValue) to \(new.effect.rawValue)" }
        if new.requiresForeground, !old.requiresForeground { return "the workflow now requires foreground input" }
        let oldKinds = Set(old.steps.map(\.action))
        let added = Set(new.steps.map(\.action)).subtracting(oldKinds).subtracting(["wait_for", "assert"])
        if !added.isEmpty { return "new action kinds: \(added.sorted().joined(separator: ", "))" }
        return nil
    }

    // MARK: Recordings

    public func saveRecording(_ recording: Recording) throws {
        let id = try PrivateFiles.checkedID(recording.id, kind: "recording")
        try PrivateFiles.write(WorkflowJSON.encode(recording), to: self.recordings.appendingPathComponent("\(id).json"))
        self.prune(self.recordings, keep: Self.maxRecordings)
    }

    public func loadRecording(_ id: String) throws -> Recording {
        let id = try PrivateFiles.checkedID(id, kind: "recording")
        let data = try PrivateFiles.read(self.recordings.appendingPathComponent("\(id).json"))
        do { return try WorkflowJSON.decode(Recording.self, from: data) } catch {
            throw WorkflowError(.schemaInvalid, "recording \(id): \(WorkflowJSON.describe(error))")
        }
    }

    public func listRecordings() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: self.recordings.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.map { String($0.dropLast(5)) }.sorted()
    }

    // MARK: Runs

    public func saveRun(_ result: WorkflowRunResult) {
        guard IDs.isSafe(result.runId) else { return }
        try? PrivateFiles.write(WorkflowJSON.encode(result), to: self.runs.appendingPathComponent("\(result.runId).json"))
        self.prune(self.runs, keep: Self.maxRuns)
    }

    func prune(_ dir: URL, keep: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path), names.count > keep else { return }
        let dated = names.filter { $0.hasSuffix(".json") }.compactMap { name -> (String, Date)? in
            let date = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.modificationDate] as? Date
            return date.map { (name, $0) }
        }.sorted { $0.1 > $1.1 }
        for (name, _) in dated.dropFirst(keep) { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
    }
}
