import Foundation

/// Append-only event store contract. Mac and iOS each have their own implementation; both speak the same shape.
public protocol SessionEventStore: AnyObject, Sendable {
    func append(_ events: [SessionEvent]) async throws
    func events(for sessionId: UUID, afterSequence: UInt64?) async throws -> [SessionEvent]
    func highestSequence(for sessionId: UUID) async throws -> UInt64?
    func deleteSession(_ id: UUID) async throws
}

public protocol SessionStore: AnyObject, Sendable {
    func upsert(_ session: Session) async throws
    func get(_ id: UUID) async throws -> Session?
    func list(includeArchived: Bool) async throws -> [Session]
    func archive(_ id: UUID) async throws
    func delete(_ id: UUID) async throws
}

public protocol DeviceStore: AnyObject, Sendable {
    func upsert(_ device: DeviceRecord) async throws
    func get(_ id: UUID) async throws -> DeviceRecord?
    func list() async throws -> [DeviceRecord]
    func revoke(_ id: UUID, reason: String?) async throws
}

public protocol ApprovalStore: AnyObject, Sendable {
    func upsert(_ approval: ApprovalRequest) async throws
    func get(_ id: UUID) async throws -> ApprovalRequest?
    func pending(for sessionId: UUID) async throws -> [ApprovalRequest]
    func updateStatus(_ id: UUID, status: ApprovalStatus, decidedAt: Date?, deviceId: UUID?) async throws
}

public protocol ContextStore: AnyObject, Sendable {
    func record(_ snapshot: ContextSnapshot) async throws
    func latest(for sessionId: UUID) async throws -> ContextSnapshot?
    func history(for sessionId: UUID, limit: Int) async throws -> [ContextSnapshot]
}

/// Project-scoped long-term memory: `MEMORY.md` index + `notes/*.md` files.
public protocol ProjectMemoryStore: AnyObject, Sendable {
    func appendNote(title: String, body: String, tags: [String]) async throws -> URL
    func listNotes() async throws -> [ProjectMemoryEntry]
    func indexMarkdown() async throws -> String
}

public struct ProjectMemoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String { fileName }
    public let fileName: String
    public let title: String
    public let createdAt: Date
    public let tags: [String]
    public init(fileName: String, title: String, createdAt: Date, tags: [String]) {
        self.fileName = fileName; self.title = title; self.createdAt = createdAt; self.tags = tags
    }
}

/// Crash report record persisted under `memory/crashes/`.
public struct CrashReport: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let sessionId: UUID?
    public let kind: CrashKind
    public let message: String
    public let stackTrace: String?
    public let timestamp: Date
    public let environment: [String: String]
    public init(
        id: UUID = UUID(),
        sessionId: UUID? = nil,
        kind: CrashKind,
        message: String,
        stackTrace: String? = nil,
        timestamp: Date = Date(),
        environment: [String: String] = [:]
    ) {
        self.id = id; self.sessionId = sessionId; self.kind = kind
        self.message = message; self.stackTrace = stackTrace
        self.timestamp = timestamp; self.environment = environment
    }
}
