import Foundation

// MARK: - Command

public struct CommandEventPayload: Codable, Hashable, Sendable {
    public let command: String
    public let workingDirectory: String?
    public let risk: RiskLevel
    public var status: CommandStatus
    public var exitCode: Int32?
    public var startedAt: Date
    public var completedAt: Date?
    public var durationMs: UInt64?
    public var outputSummary: String?
    public var outputBytes: Int?
    public var stderrPreview: String?

    public init(
        command: String,
        workingDirectory: String? = nil,
        risk: RiskLevel = .low,
        status: CommandStatus = .running,
        exitCode: Int32? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        durationMs: UInt64? = nil,
        outputSummary: String? = nil,
        outputBytes: Int? = nil,
        stderrPreview: String? = nil
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.risk = risk
        self.status = status
        self.exitCode = exitCode
        self.startedAt = startedAt.dnpQuantized
        self.completedAt = completedAt?.dnpQuantized
        self.durationMs = durationMs
        self.outputSummary = outputSummary
        self.outputBytes = outputBytes
        self.stderrPreview = stderrPreview
    }
}

public enum CommandStatus: String, Codable, Hashable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

public enum RiskLevel: String, Codable, Hashable, Sendable, CaseIterable {
    case low
    case medium
    case high
    case critical

    public var sortIndex: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .critical: return 3
        }
    }
}

// MARK: - Code edit

public struct CodeEditPayload: Codable, Hashable, Sendable {
    public let filePath: String
    public let changeKind: CodeChangeKind
    public let linesAdded: Int
    public let linesRemoved: Int
    public let summary: String
    public let diffPreview: String?
    public let toolSource: String?

    public init(
        filePath: String,
        changeKind: CodeChangeKind,
        linesAdded: Int,
        linesRemoved: Int,
        summary: String,
        diffPreview: String? = nil,
        toolSource: String? = nil
    ) {
        self.filePath = filePath
        self.changeKind = changeKind
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.summary = summary
        self.diffPreview = diffPreview
        self.toolSource = toolSource
    }
}

public enum CodeChangeKind: String, Codable, Hashable, Sendable {
    case created
    case modified
    case deleted
    case renamed
    case multiEdit
}

// MARK: - File changed

public struct FileChangedPayload: Codable, Hashable, Sendable {
    public let path: String
    public let operation: FileOperation
    public let toolSource: String?
    public let bytes: Int?

    public init(path: String, operation: FileOperation, toolSource: String? = nil, bytes: Int? = nil) {
        self.path = path
        self.operation = operation
        self.toolSource = toolSource
        self.bytes = bytes
    }
}

public enum FileOperation: String, Codable, Hashable, Sendable {
    case created, modified, deleted, renamed, permissionsChanged
}

// MARK: - Tool activity

public struct ToolActivityPayload: Codable, Hashable, Sendable {
    public let toolName: String
    public let provider: ToolProvider
    public let inputDigest: String?
    public let outputDigest: String?
    public var status: ToolActivityStatus
    public let startedAt: Date
    public var completedAt: Date?
    public var durationMs: UInt64?
    public var failureReason: String?

    public init(
        toolName: String,
        provider: ToolProvider,
        inputDigest: String? = nil,
        outputDigest: String? = nil,
        status: ToolActivityStatus = .started,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        durationMs: UInt64? = nil,
        failureReason: String? = nil
    ) {
        self.toolName = toolName
        self.provider = provider
        self.inputDigest = inputDigest
        self.outputDigest = outputDigest
        self.status = status
        self.startedAt = startedAt.dnpQuantized
        self.completedAt = completedAt?.dnpQuantized
        self.durationMs = durationMs
        self.failureReason = failureReason
    }
}

public enum ToolProvider: String, Codable, Hashable, Sendable {
    case builtIn   // Bash, Read, Edit, Write, Grep, Glob, LS, TodoWrite, etc.
    case mcp
    case subagent
    case unknown
}

public enum ToolActivityStatus: String, Codable, Hashable, Sendable {
    case started
    case completed
    case failed
    case cancelled
    case permissionDenied
}

// MARK: - Approval

public struct ApprovalEventPayload: Codable, Hashable, Sendable {
    public let approvalId: UUID
    public let lifecycle: ApprovalLifecycle
    public let actionSummary: String
    /// Full request body — populated by the Mac when the lifecycle is `.requested` so the
    /// iOS client can show the approval card with the right title, target, and risk level.
    /// Optional for backward compatibility with older Macs that don't send it.
    public let request: ApprovalRequest?

    public init(approvalId: UUID, lifecycle: ApprovalLifecycle, actionSummary: String,
                request: ApprovalRequest? = nil) {
        self.approvalId = approvalId
        self.lifecycle = lifecycle
        self.actionSummary = actionSummary
        self.request = request
    }
}

public enum ApprovalLifecycle: String, Codable, Hashable, Sendable {
    case requested
    case sentToIOS
    case viewed
    case approved
    case rejected
    case expired
    case appliedToRuntime
    case failed
}

// MARK: - Message

public struct MessagePayload: Codable, Hashable, Sendable {
    public let role: MessageRole
    public let text: String
    public let attachments: [MessageAttachment]

    public init(role: MessageRole, text: String, attachments: [MessageAttachment] = []) {
        self.role = role
        self.text = text
        self.attachments = attachments
    }
}

public enum MessageRole: String, Codable, Hashable, Sendable { case user, assistant, system, thinking }

public struct MessageAttachment: Codable, Hashable, Sendable {
    public let kind: AttachmentKind
    public let path: String?
    public let preview: String?
    public init(kind: AttachmentKind, path: String? = nil, preview: String? = nil) {
        self.kind = kind; self.path = path; self.preview = preview
    }
}

public enum AttachmentKind: String, Codable, Hashable, Sendable { case file, image, codeBlock, link }

// MARK: - Warning / Error / Crash

public struct WarningPayload: Codable, Hashable, Sendable {
    public let code: String
    public let title: String
    public let detail: String?
    public let suggestedAction: String?
    /// When true, the receiving client should fire a system attention banner in addition to
    /// rendering the in-app warning card. Used by the Mac for Claude `Notification` hook
    /// messages (e.g. "Claude is waiting for your input") that don't go through the regular
    /// approval pipeline. Optional + defaults to `nil` so older clients ignore it cleanly.
    public let attention: Bool?
    public init(code: String, title: String, detail: String? = nil,
                suggestedAction: String? = nil, attention: Bool? = nil) {
        self.code = code; self.title = title; self.detail = detail
        self.suggestedAction = suggestedAction; self.attention = attention
    }
}

public struct ErrorPayload: Codable, Hashable, Sendable {
    public let code: String
    public let title: String
    public let detail: String?
    public let suggestedAction: String?
    public let diagnosticsRef: String?
    public init(code: String, title: String, detail: String? = nil, suggestedAction: String? = nil, diagnosticsRef: String? = nil) {
        self.code = code; self.title = title; self.detail = detail
        self.suggestedAction = suggestedAction; self.diagnosticsRef = diagnosticsRef
    }
}

public struct CrashPayload: Codable, Hashable, Sendable {
    public let kind: CrashKind
    public let message: String
    public let stackTracePreview: String?
    public let reportPath: String?
    public init(kind: CrashKind, message: String, stackTracePreview: String? = nil, reportPath: String? = nil) {
        self.kind = kind; self.message = message
        self.stackTracePreview = stackTracePreview; self.reportPath = reportPath
    }
}

public enum CrashKind: String, Codable, Hashable, Sendable {
    case ptyExitedUnexpectedly
    case claudeExitedUnexpectedly
    case bridgeServerCrashed
    case uncaughtSwiftException
    case signalReceived
    case other
}

// MARK: - Subagent

public struct SubagentPayload: Codable, Hashable, Sendable {
    public let subagentName: String
    public var status: SubagentStatus
    public let promptDigest: String?
    public init(subagentName: String, status: SubagentStatus, promptDigest: String? = nil) {
        self.subagentName = subagentName; self.status = status; self.promptDigest = promptDigest
    }
}

public enum SubagentStatus: String, Codable, Hashable, Sendable {
    case started, completed, failed
}

// MARK: - Raw

/// Escape hatch for events whose schema isn't yet recognized. Mac developer mode can inspect; iOS shows compact fallback.
public struct RawPayload: Codable, Hashable, Sendable {
    public let kind: String
    public let json: String
    public init(kind: String, json: String) { self.kind = kind; self.json = json }
}
