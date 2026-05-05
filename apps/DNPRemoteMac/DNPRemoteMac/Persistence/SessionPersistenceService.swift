import Foundation

/// Owns on-disk persistence under `<repoRoot>/memory/sessions/{id}/`. Append-only JSONL events,
/// a growing transcript.md, plus metadata.json and periodic summary.md.
actor SessionPersistenceService {

    let sessions: DiskBackedSessionStore
    let approvals = InMemoryApprovalStore()
    let devices = InMemoryDeviceStore()
    let context = InMemoryContextStore()

    let memoryRoot: URL

    init() {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/DNPRemoteMac/memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.memoryRoot = root
        self.sessions = DiskBackedSessionStore(
            rootDir: root.appendingPathComponent("sessions", isDirectory: true)
        )
    }

    func bootstrap() async {
        // Load any sessions left on disk by a previous run. Each `sessions/<id>/` carries a
        // `metadata.json` (Session struct) plus `events.jsonl` + `transcript.md`. Restoring
        // metadata here repopulates the in-memory list; `MacAppViewModel.bootstrap` then
        // reloads the per-session feed via `loadEvents` and re-launches `claude --resume`.
        await sessions.load()
    }

    func sessionDir(_ id: UUID) -> URL {
        let dir = memoryRoot.appendingPathComponent("sessions/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func appendEvent(_ event: SessionEvent) async {
        let dir = sessionDir(event.sessionId)
        // JSONL
        if let data = try? DNPCoders.encode(event) {
            let line = data + Data([0x0A])
            let url = dir.appendingPathComponent("events.jsonl")
            if FileManager.default.fileExists(atPath: url.path) {
                if let h = try? FileHandle(forWritingTo: url) {
                    // `_ =` silences "result of 'try?' is unused" — these
                    // are fire-and-forget appends; if the file handle
                    // can't seek/write/close we drop the line rather
                    // than crashing the persistence layer.
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: line)
                    try? h.close()
                }
            } else {
                try? line.write(to: url)
            }
        }
        // Transcript.md
        let md = MarkdownTranscript.render(event)
        let mdURL = dir.appendingPathComponent("transcript.md")
        if FileManager.default.fileExists(atPath: mdURL.path) {
            if let h = try? FileHandle(forWritingTo: mdURL) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(md.utf8))
                try? h.close()
            }
        } else {
            try? Data(md.utf8).write(to: mdURL)
        }
    }

    /// Read every event we've persisted for this session, oldest first. Returns an empty array
    /// if the file doesn't exist (fresh session) or any line fails to decode (best-effort).
    func loadEvents(_ sessionId: UUID) async -> [SessionEvent] {
        let url = sessionDir(sessionId).appendingPathComponent("events.jsonl")
        guard let data = try? Data(contentsOf: url),
              let str = String(data: data, encoding: .utf8) else { return [] }
        var out: [SessionEvent] = []
        for line in str.split(separator: "\n", omittingEmptySubsequences: true) {
            if let evt = try? DNPCoders.decode(SessionEvent.self, from: Data(line.utf8)) {
                out.append(evt)
            }
        }
        return out
    }

    func writeMetadata(_ session: Session) async {
        let dir = sessionDir(session.id)
        if let data = try? DNPCoders.encode(session) {
            try? data.write(to: dir.appendingPathComponent("metadata.json"))
        }
    }

    /// Generate a periodic summary.md. Caller should call after material milestones.
    func writeSummary(sessionId: UUID, summary: String) async {
        let dir = sessionDir(sessionId)
        try? Data(summary.utf8).write(to: dir.appendingPathComponent("summary.md"))
    }

    /// Wipe every persisted session (metadata + events.jsonl + transcript.md +
    /// summary.md) whose `projectPath` matches `projectURL`. Used by the
    /// "Delete history" branch of the workspace-close confirmation: when the
    /// user picks "Delete", the next time they reopen the project there is
    /// nothing left to rehydrate, so it starts clean.
    func purgeSessions(forProjectAt projectURL: URL) async -> Int {
        let target = projectURL.standardizedFileURL.path
        let all = (try? await sessions.list(includeArchived: true)) ?? []
        var removed = 0
        for session in all where session.projectPath == target {
            try? await sessions.delete(session.id)
            removed += 1
        }
        return removed
    }

    /// Lightweight check used by the close-confirmation prompt to decide
    /// whether to ask at all — no need to interrupt the user with a
    /// "Save / Delete history?" sheet when there is no history to act on.
    func hasSessions(forProjectAt projectURL: URL) async -> Bool {
        let target = projectURL.standardizedFileURL.path
        let all = (try? await sessions.list(includeArchived: true)) ?? []
        return all.contains { $0.projectPath == target }
    }
}

// MARK: - Disk-backed session store

/// Real persistence for session metadata. Each session lives at `<rootDir>/<id>/metadata.json`,
/// alongside its `events.jsonl` + `transcript.md` (written by `SessionPersistenceService`).
/// `load()` is called once at app launch (from `bootstrap`) and re-hydrates the in-memory
/// cache; subsequent mutations write through to disk so a crash or quit doesn't lose state.
/// `delete(_:)` removes the entire session directory — used by `confirmClose` so the user
/// gets the "files vanish at session end" semantics they asked for.
actor DiskBackedSessionStore: SessionStore {
    private let rootDir: URL
    private var byId: [UUID: Session] = [:]

    init(rootDir: URL) {
        self.rootDir = rootDir
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    /// Scan every `<rootDir>/<id>/metadata.json` and pull each Session into the cache.
    /// Tolerant of missing / unreadable files — a corrupt directory just gets skipped.
    func load() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard isDir else { continue }
            let metaURL = entry.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let session = try? DNPCoders.decode(Session.self, from: data) else { continue }
            byId[session.id] = session
        }
    }

    func upsert(_ session: Session) async throws {
        byId[session.id] = session
        writeMetadata(session)
    }

    func get(_ id: UUID) async throws -> Session? { byId[id] }

    func list(includeArchived: Bool) async throws -> [Session] {
        let all = Array(byId.values).sorted { $0.updatedAt > $1.updatedAt }
        return includeArchived ? all : all.filter { $0.status != .ended }
    }

    func archive(_ id: UUID) async throws {
        guard var s = byId[id] else { return }
        s.status = .ended
        s.updatedAt = Date()
        byId[id] = s
        writeMetadata(s)
    }

    func delete(_ id: UUID) async throws {
        byId.removeValue(forKey: id)
        let dir = rootDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeMetadata(_ session: Session) {
        let dir = rootDir.appendingPathComponent(session.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? DNPCoders.encode(session) {
            try? data.write(to: dir.appendingPathComponent("metadata.json"), options: .atomic)
        }
    }
}

// MARK: - In-memory store fallbacks (replace with Core Data / SQLite later)

actor InMemoryApprovalStore: ApprovalStore {
    private var byId: [UUID: ApprovalRequest] = [:]
    func upsert(_ approval: ApprovalRequest) async throws { byId[approval.id] = approval }
    func get(_ id: UUID) async throws -> ApprovalRequest? { byId[id] }
    func pending(for sessionId: UUID) async throws -> [ApprovalRequest] {
        byId.values.filter { $0.sessionId == sessionId && $0.status != .approved && $0.status != .rejected && $0.status != .expired }
    }
    func updateStatus(_ id: UUID, status: ApprovalStatus, decidedAt: Date?, deviceId: UUID?) async throws {
        guard var x = byId[id] else { return }
        x.status = status
        x.decidedAt = decidedAt
        x.decidedByDeviceId = deviceId
        byId[id] = x
    }
}

actor InMemoryDeviceStore: DeviceStore {
    private var byId: [UUID: DeviceRecord] = [:]
    func upsert(_ device: DeviceRecord) async throws { byId[device.id] = device }
    func get(_ id: UUID) async throws -> DeviceRecord? { byId[id] }
    func list() async throws -> [DeviceRecord] { Array(byId.values) }
    func revoke(_ id: UUID, reason: String?) async throws {
        guard var x = byId[id] else { return }
        x.revoked = true; x.trusted = false
        x.notes = reason
        byId[id] = x
    }
}

actor InMemoryContextStore: ContextStore {
    private var byId: [UUID: [ContextSnapshot]] = [:]
    func record(_ snapshot: ContextSnapshot) async throws {
        byId[snapshot.sessionId, default: []].append(snapshot)
    }
    func latest(for sessionId: UUID) async throws -> ContextSnapshot? {
        byId[sessionId]?.last
    }
    func history(for sessionId: UUID, limit: Int) async throws -> [ContextSnapshot] {
        Array((byId[sessionId] ?? []).suffix(limit))
    }
}
