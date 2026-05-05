import Foundation

/// The single canonical event type that flows from Mac runtime to iOS feed.
/// Every PTY byte / hook payload / approval / context update is normalized into a `SessionEvent`.
public struct SessionEvent: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sessionId: UUID
    public let sequence: UInt64
    public let timestamp: Date
    public let type: SessionEventType
    public let severity: SessionEventSeverity
    public let source: SessionSource
    public let title: String
    public let summary: String?
    public let payload: SessionEventPayload?

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        sequence: UInt64,
        timestamp: Date = Date(),
        type: SessionEventType,
        severity: SessionEventSeverity = .info,
        source: SessionSource,
        title: String,
        summary: String? = nil,
        payload: SessionEventPayload? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.sequence = sequence
        self.timestamp = timestamp.dnpQuantized
        self.type = type
        self.severity = severity
        self.source = source
        self.title = title
        self.summary = summary
        self.payload = payload
    }
}

public enum SessionEventType: String, Codable, Hashable, Sendable, CaseIterable {
    case userMessage
    case assistantMessage
    case thinkingSummary
    case commandStarted
    case commandOutput
    case commandCompleted
    case codeEditSummary
    case fileChanged
    case toolActivity
    case approvalRequired
    case approvalResult
    case warning
    case error
    case contextUpdate
    case sessionStatusUpdate
    case sessionStarted
    case sessionEnded
    case compactStarted
    case compactCompleted
    case subagentStarted
    case subagentCompleted
    case crash
    case unknown
}

public enum SessionEventSeverity: String, Codable, Hashable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical
}

public enum SessionEventPayload: Codable, Hashable, Sendable {
    case command(CommandEventPayload)
    case codeEdit(CodeEditPayload)
    case fileChanged(FileChangedPayload)
    case toolActivity(ToolActivityPayload)
    case approval(ApprovalEventPayload)
    case context(ContextSnapshot)
    case message(MessagePayload)
    case warning(WarningPayload)
    case error(ErrorPayload)
    case crash(CrashPayload)
    case subagent(SubagentPayload)
    case raw(RawPayload)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable {
        case command, codeEdit, fileChanged, toolActivity, approval, context
        case message, warning, error, crash, subagent, raw
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .command(let v):       try c.encode(Kind.command, forKey: .kind);      try c.encode(v, forKey: .value)
        case .codeEdit(let v):      try c.encode(Kind.codeEdit, forKey: .kind);     try c.encode(v, forKey: .value)
        case .fileChanged(let v):   try c.encode(Kind.fileChanged, forKey: .kind);  try c.encode(v, forKey: .value)
        case .toolActivity(let v):  try c.encode(Kind.toolActivity, forKey: .kind); try c.encode(v, forKey: .value)
        case .approval(let v):      try c.encode(Kind.approval, forKey: .kind);     try c.encode(v, forKey: .value)
        case .context(let v):       try c.encode(Kind.context, forKey: .kind);      try c.encode(v, forKey: .value)
        case .message(let v):       try c.encode(Kind.message, forKey: .kind);      try c.encode(v, forKey: .value)
        case .warning(let v):       try c.encode(Kind.warning, forKey: .kind);      try c.encode(v, forKey: .value)
        case .error(let v):         try c.encode(Kind.error, forKey: .kind);        try c.encode(v, forKey: .value)
        case .crash(let v):         try c.encode(Kind.crash, forKey: .kind);        try c.encode(v, forKey: .value)
        case .subagent(let v):      try c.encode(Kind.subagent, forKey: .kind);     try c.encode(v, forKey: .value)
        case .raw(let v):           try c.encode(Kind.raw, forKey: .kind);          try c.encode(v, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .command:      self = .command(try c.decode(CommandEventPayload.self, forKey: .value))
        case .codeEdit:     self = .codeEdit(try c.decode(CodeEditPayload.self, forKey: .value))
        case .fileChanged:  self = .fileChanged(try c.decode(FileChangedPayload.self, forKey: .value))
        case .toolActivity: self = .toolActivity(try c.decode(ToolActivityPayload.self, forKey: .value))
        case .approval:     self = .approval(try c.decode(ApprovalEventPayload.self, forKey: .value))
        case .context:      self = .context(try c.decode(ContextSnapshot.self, forKey: .value))
        case .message:      self = .message(try c.decode(MessagePayload.self, forKey: .value))
        case .warning:      self = .warning(try c.decode(WarningPayload.self, forKey: .value))
        case .error:        self = .error(try c.decode(ErrorPayload.self, forKey: .value))
        case .crash:        self = .crash(try c.decode(CrashPayload.self, forKey: .value))
        case .subagent:     self = .subagent(try c.decode(SubagentPayload.self, forKey: .value))
        case .raw:          self = .raw(try c.decode(RawPayload.self, forKey: .value))
        }
    }
}
