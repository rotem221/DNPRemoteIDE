import Foundation

public struct Session: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var projectPath: String
    public var projectName: String
    public var createdAt: Date
    public var updatedAt: Date
    public var status: SessionStatus
    public var lastActivityAt: Date?
    public var pendingApprovalCount: Int
    public var contextHealth: ContextHealth
    /// Claude's own `session_id` — captured from the SessionStart hook / transcript filename.
    /// Persisted so we can `claude --resume <id>` after the Mac app is killed and reopened,
    /// keeping the conversation alive across app restarts.
    public var claudeSessionId: String?

    /// GitHub backing for this session's project, when present. Mac populates by inspecting
    /// `<projectPath>/.git/config` on session creation; iOS surfaces a badge + branch chip.
    public var gitHub: SessionGitHubInfo?

    public init(
        id: UUID = UUID(),
        title: String,
        projectPath: String,
        projectName: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: SessionStatus = .idle,
        lastActivityAt: Date? = nil,
        pendingApprovalCount: Int = 0,
        contextHealth: ContextHealth = .unknown,
        claudeSessionId: String? = nil,
        gitHub: SessionGitHubInfo? = nil
    ) {
        self.id = id
        self.title = title
        self.projectPath = projectPath
        self.projectName = projectName
        self.createdAt = createdAt.dnpQuantized
        self.updatedAt = updatedAt.dnpQuantized
        self.status = status
        self.lastActivityAt = lastActivityAt?.dnpQuantized
        self.pendingApprovalCount = pendingApprovalCount
        self.contextHealth = contextHealth
        self.claudeSessionId = claudeSessionId
        self.gitHub = gitHub
    }
}

/// Minimal GitHub-backing snapshot attached to a `Session` or `ProjectInfoPayload` so iOS can
/// render the GitHub badge and current branch without owning the `gh` CLI itself.
public struct SessionGitHubInfo: Codable, Hashable, Sendable {
    public let nameWithOwner: String
    public let webURL: String?
    public let currentBranch: String?
    public init(nameWithOwner: String, webURL: String? = nil, currentBranch: String? = nil) {
        self.nameWithOwner = nameWithOwner
        self.webURL = webURL
        self.currentBranch = currentBranch
    }
}

public enum SessionStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case idle
    case starting
    case running
    case waitingForApproval
    case waitingForUser
    case compacting
    case ending
    case ended
    case crashed
    case disconnected
}

public enum SessionSource: String, Codable, Hashable, Sendable {
    case mac
    case ios
    case hookRelay
    case parser
    case system
    case user
}
