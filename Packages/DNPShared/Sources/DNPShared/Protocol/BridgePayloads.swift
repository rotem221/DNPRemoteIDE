import Foundation

// MARK: - Hello / Heartbeat

public struct HelloPayload: Codable, Hashable, Sendable {
    public let deviceId: UUID
    public let deviceName: String
    public let platform: DevicePlatform
    public let appVersion: String
    public let protocolVersion: Int
    public init(deviceId: UUID, deviceName: String, platform: DevicePlatform, appVersion: String, protocolVersion: Int = ProtocolConstants.version) {
        self.deviceId = deviceId; self.deviceName = deviceName; self.platform = platform
        self.appVersion = appVersion; self.protocolVersion = protocolVersion
    }
}

public struct HeartbeatPayload: Codable, Hashable, Sendable {
    public let sentAt: Date
    public let connectionUptimeSeconds: TimeInterval
    public init(sentAt: Date = Date(), connectionUptimeSeconds: TimeInterval) {
        self.sentAt = sentAt; self.connectionUptimeSeconds = connectionUptimeSeconds
    }
}

// MARK: - Sessions

public struct SessionListRequestPayload: Codable, Hashable, Sendable {
    public let includeArchived: Bool
    public init(includeArchived: Bool = false) { self.includeArchived = includeArchived }
}

public struct SessionListResponsePayload: Codable, Hashable, Sendable {
    public let sessions: [Session]
    public init(sessions: [Session]) { self.sessions = sessions }
}

public struct SubscribeSessionPayload: Codable, Hashable, Sendable {
    public let sessionId: UUID
    public let lastSequenceSeen: UInt64?     // for backfill resume
    public init(sessionId: UUID, lastSequenceSeen: UInt64? = nil) {
        self.sessionId = sessionId; self.lastSequenceSeen = lastSequenceSeen
    }
}

public struct UnsubscribeSessionPayload: Codable, Hashable, Sendable {
    public let sessionId: UUID
    public init(sessionId: UUID) { self.sessionId = sessionId }
}

public struct EventBatchPayload: Codable, Hashable, Sendable {
    public let sessionId: UUID
    public let events: [SessionEvent]
    public let isBackfill: Bool
    public let highestSequence: UInt64?
    public init(sessionId: UUID, events: [SessionEvent], isBackfill: Bool, highestSequence: UInt64?) {
        self.sessionId = sessionId; self.events = events
        self.isBackfill = isBackfill; self.highestSequence = highestSequence
    }
}

public struct LiveEventPayload: Codable, Hashable, Sendable {
    public let event: SessionEvent
    public init(event: SessionEvent) { self.event = event }
}

// MARK: - User actions

public struct UserPromptPayload: Codable, Hashable, Sendable {
    public let sessionId: UUID
    public let text: String
    public let attachments: [MessageAttachment]
    public init(sessionId: UUID, text: String, attachments: [MessageAttachment] = []) {
        self.sessionId = sessionId; self.text = text; self.attachments = attachments
    }
}

public struct ApprovalResponsePayload: Codable, Hashable, Sendable {
    public let response: ApprovalResponse
    public init(response: ApprovalResponse) { self.response = response }
}

public struct NewSessionRequestPayload: Codable, Hashable, Sendable {
    public let projectPath: String?
    public init(projectPath: String? = nil) { self.projectPath = projectPath }
}

/// iOS → Mac: end the named session (Mac runs `confirmClose(sessionId:)`).
public struct CloseSessionRequestPayload: Codable, Hashable, Sendable {
    public let sessionId: UUID
    public init(sessionId: UUID) { self.sessionId = sessionId }
}

/// iOS → Mac: interrupt the currently running command in the given session (e.g. Claude turn).
/// Mac forwards SIGINT (Ctrl-C) into that session's PTY.
public struct CancelRunningPayload: Codable, Hashable, Sendable {
    public let sessionId: UUID
    public init(sessionId: UUID) { self.sessionId = sessionId }
}

/// iOS → Mac: user-driven "force allow" — types `1\r` into the named session's PTY
/// regardless of whether our PTY prompt detector currently sees Claude's choice
/// menu. This is the escape hatch the user takes when our auto-detection misses
/// a real prompt and an approval card never showed on iOS. The Mac decides how
/// strict to be about safety guards (see `MacAppViewModel.forceApprove(sessionId:)`).
public struct ForceApprovePayload: Codable, Hashable, Sendable {
    public let sessionId: UUID
    public init(sessionId: UUID) { self.sessionId = sessionId }
}

/// Mac → iOS: latest Claude Code usage snapshot fetched from
/// `https://api.anthropic.com/api/oauth/usage`. Drives the AI Usage widget
/// in the Mac status bar and the AI Usage rows inside the iOS Context popover.
public struct AIUsageBroadcastPayload: Codable, Hashable, Sendable {
    public let snapshot: AIUsageSnapshot
    public init(snapshot: AIUsageSnapshot) { self.snapshot = snapshot }
}

/// Mac → iOS: which session the IDE currently has focused. Sent every
/// time the user picks a different session pane on the Mac, and
/// re-sent to a fresh iOS client on connect (so the iPhone matches
/// the IDE the moment the bridge comes up). `sessionId` is nil when
/// no session is currently selected (e.g. the focused workspace has
/// nothing live), which clears any stale auto-follow on iOS.
public struct ActiveSessionBroadcastPayload: Codable, Hashable, Sendable {
    public let sessionId: UUID?
    public init(sessionId: UUID?) { self.sessionId = sessionId }
}

// MARK: - File explorer

/// Broadcast from Mac → iOS whenever the active project changes (or on hello/connect).
/// `homePath` is the user's $HOME on the Mac so iOS can offer "Browse home" navigation in the
/// file explorer when the user wants to leave the project root.
/// `tailscaleHostname`/`tailscaleIPv4` are populated when the Mac detects a running Tailscale
/// daemon, so the iOS client can switch to the tailnet endpoint and reach the Mac off-LAN.
public struct ProjectInfoPayload: Codable, Hashable, Sendable {
    public let rootPath: String?
    public let displayName: String?
    public let homePath: String?
    public let tailscaleHostname: String?
    public let tailscaleIPv4: String?
    /// GitHub backing of the active project — owner/repo + current branch, when the
    /// project is a Git repo with an `origin` pointing at github.com. Nil for non-GitHub
    /// projects or when no project is open.
    public let gitHub: SessionGitHubInfo?
    /// Current `gh auth status` snapshot — drives the GitHub indicator in iOS Settings and
    /// the file-explorer's "Browse Repos" entry. Nil when `gh` is not installed.
    public let gitHubAuth: GitHubAuthInfoPayload?
    /// macOS lock state at the moment this payload was assembled.
    /// `nil` for older Mac builds that pre-date the lock-state probe —
    /// iOS treats `nil` the same as "we don't know" and falls back to
    /// the historical "always show the unlock affordance" behaviour.
    /// `true` = lock screen is up (unlock button is meaningful);
    /// `false` = the user is already signed in (button can hide).
    public let isLocked: Bool?
    public init(rootPath: String?, displayName: String?, homePath: String? = nil,
                tailscaleHostname: String? = nil, tailscaleIPv4: String? = nil,
                gitHub: SessionGitHubInfo? = nil,
                gitHubAuth: GitHubAuthInfoPayload? = nil,
                isLocked: Bool? = nil) {
        self.rootPath = rootPath
        self.displayName = displayName
        self.homePath = homePath
        self.tailscaleHostname = tailscaleHostname
        self.tailscaleIPv4 = tailscaleIPv4
        self.gitHub = gitHub
        self.gitHubAuth = gitHubAuth
        self.isLocked = isLocked
    }
}

/// Snapshot of `gh auth status` shipped to iOS — purely informational; iOS never invokes
/// `gh` directly, the Mac is the single source of truth.
public struct GitHubAuthInfoPayload: Codable, Hashable, Sendable {
    public let installed: Bool
    public let signedIn: Bool
    public let user: String?
    public let host: String?
    public let scopes: String?
    public init(installed: Bool, signedIn: Bool, user: String? = nil, host: String? = nil, scopes: String? = nil) {
        self.installed = installed
        self.signedIn = signedIn
        self.user = user
        self.host = host
        self.scopes = scopes
    }
}

/// iOS → Mac: ask for the user's GitHub repos via `gh repo list`. Mac runs the command,
/// parses the JSON, and ships the result back as `GitHubRepoListResponsePayload`.
public struct GitHubRepoListRequestPayload: Codable, Hashable, Sendable {
    public let requestId: UUID
    public let limit: Int
    public init(requestId: UUID = UUID(), limit: Int = 50) {
        self.requestId = requestId; self.limit = limit
    }
}

public struct GitHubRepoSummary: Codable, Hashable, Sendable {
    public let nameWithOwner: String
    public let description: String
    public let isPrivate: Bool
    public let url: String
    public init(nameWithOwner: String, description: String, isPrivate: Bool, url: String) {
        self.nameWithOwner = nameWithOwner
        self.description = description
        self.isPrivate = isPrivate
        self.url = url
    }
}

public struct GitHubRepoListResponsePayload: Codable, Hashable, Sendable {
    public let requestId: UUID
    public let repos: [GitHubRepoSummary]
    public let error: String?
    public init(requestId: UUID, repos: [GitHubRepoSummary], error: String? = nil) {
        self.requestId = requestId; self.repos = repos; self.error = error
    }
}

/// iOS → Mac: adopt the named GitHub repo as the active project (clone into
/// `~/Developer/<repo>` if missing). Mac broadcasts a fresh `ProjectInfoPayload` on success.
public struct GitHubAdoptRepoRequestPayload: Codable, Hashable, Sendable {
    public let requestId: UUID
    public let nameWithOwner: String
    public init(requestId: UUID = UUID(), nameWithOwner: String) {
        self.requestId = requestId; self.nameWithOwner = nameWithOwner
    }
}

/// iOS → Mac: ask the Mac to present an open-panel and switch the active project.
public struct OpenFolderRequestPayload: Codable, Hashable, Sendable {
    public init() {}
}

/// iOS → Mac: set the active project root to the given absolute path (must live under $HOME).
/// Used by the iOS-side folder picker so the user picks the directory directly on iOS — no
/// Mac-side NSOpenPanel — and the Mac just adopts the chosen path.
public struct SetProjectRootRequestPayload: Codable, Hashable, Sendable {
    public let path: String
    public init(path: String) { self.path = path }
}

/// iOS → Mac: list the entries of one directory under the active project root.
/// `relativePath` of "" means the project root.
public struct DirectoryListingRequestPayload: Codable, Hashable, Sendable {
    public let requestId: UUID
    public let relativePath: String
    public init(requestId: UUID = UUID(), relativePath: String) {
        self.requestId = requestId; self.relativePath = relativePath
    }
}

public struct DirectoryEntry: Codable, Hashable, Sendable {
    public let name: String
    public let isDirectory: Bool
    public let sizeBytes: Int64
    public init(name: String, isDirectory: Bool, sizeBytes: Int64) {
        self.name = name; self.isDirectory = isDirectory; self.sizeBytes = sizeBytes
    }
}

public struct DirectoryListingResponsePayload: Codable, Hashable, Sendable {
    public let requestId: UUID
    public let relativePath: String
    public let entries: [DirectoryEntry]
    public let error: String?
    public init(requestId: UUID, relativePath: String, entries: [DirectoryEntry], error: String? = nil) {
        self.requestId = requestId
        self.relativePath = relativePath
        self.entries = entries
        self.error = error
    }
}

/// iOS → Mac: read a single file. The Mac returns either UTF-8 text (preferred) or raw bytes
/// (for binary files like images).
public struct FileContentRequestPayload: Codable, Hashable, Sendable {
    public let requestId: UUID
    public let relativePath: String
    public let maxBytes: Int
    public init(requestId: UUID = UUID(), relativePath: String, maxBytes: Int = 1_500_000) {
        self.requestId = requestId; self.relativePath = relativePath; self.maxBytes = maxBytes
    }
}

/// iOS → Mac: save text content back to a file.
public struct FileWriteRequestPayload: Codable, Hashable, Sendable {
    public let requestId: UUID
    public let path: String
    public let utf8Text: String
    public init(requestId: UUID = UUID(), path: String, utf8Text: String) {
        self.requestId = requestId
        self.path = path
        self.utf8Text = utf8Text
    }
}

public struct FileWriteResponsePayload: Codable, Hashable, Sendable {
    public let requestId: UUID
    public let path: String
    public let success: Bool
    public let error: String?
    public init(requestId: UUID, path: String, success: Bool, error: String? = nil) {
        self.requestId = requestId; self.path = path; self.success = success; self.error = error
    }
}

/// iOS → Mac: recursive name+content search starting at `rootPath`.
/// `query` matches file names (always) and file content (when `searchContent == true`).
public struct FileSearchRequestPayload: Codable, Hashable, Sendable {
    public let requestId: UUID
    public let rootPath: String
    public let query: String
    public let maxResults: Int
    public let searchContent: Bool
    public init(requestId: UUID = UUID(), rootPath: String, query: String,
                maxResults: Int = 200, searchContent: Bool = true) {
        self.requestId = requestId
        self.rootPath = rootPath
        self.query = query
        self.maxResults = maxResults
        self.searchContent = searchContent
    }
}

public struct FileSearchHit: Codable, Hashable, Sendable {
    public let path: String              // absolute path on the Mac
    public let isDirectory: Bool
    public let lineNumber: Int?          // first matching line (nil for name-only matches)
    public let snippet: String?
    public init(path: String, isDirectory: Bool, lineNumber: Int? = nil, snippet: String? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.lineNumber = lineNumber
        self.snippet = snippet
    }
}

public struct FileSearchResponsePayload: Codable, Hashable, Sendable {
    public let requestId: UUID
    public let query: String
    public let hits: [FileSearchHit]
    public let truncated: Bool
    public let error: String?
    public init(requestId: UUID, query: String, hits: [FileSearchHit],
                truncated: Bool = false, error: String? = nil) {
        self.requestId = requestId
        self.query = query
        self.hits = hits
        self.truncated = truncated
        self.error = error
    }
}

public struct FileContentResponsePayload: Codable, Hashable, Sendable {
    public let requestId: UUID
    public let relativePath: String
    public let mimeType: String
    public let utf8Text: String?
    public let binary: Data?
    public let truncated: Bool
    public let error: String?
    public init(requestId: UUID, relativePath: String, mimeType: String,
                utf8Text: String? = nil, binary: Data? = nil,
                truncated: Bool = false, error: String? = nil) {
        self.requestId = requestId
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.utf8Text = utf8Text
        self.binary = binary
        self.truncated = truncated
        self.error = error
    }
}

/// iOS → Mac transfer of a binary attachment. Mac writes it under the active project's
/// `tempfiles/` directory; iOS later references it in a `userPrompt` as `@tempfiles/<filename>`.
/// `data` is base64-encoded over the wire (JSON limitation).
public struct AttachmentTransferPayload: Codable, Hashable, Sendable {
    public let sessionId: UUID
    public let attachmentId: UUID
    public let filename: String
    public let mimeType: String
    public let data: Data
    public init(sessionId: UUID, attachmentId: UUID = UUID(),
                filename: String, mimeType: String, data: Data) {
        self.sessionId = sessionId
        self.attachmentId = attachmentId
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

// MARK: - Errors / Revoke / Reconnect

public struct BridgeErrorPayload: Codable, Hashable, Sendable {
    public let code: BridgeErrorCode
    public let message: String
    public let referencingMessageId: UUID?
    public init(code: BridgeErrorCode, message: String, referencingMessageId: UUID? = nil) {
        self.code = code; self.message = message; self.referencingMessageId = referencingMessageId
    }
}

public enum BridgeErrorCode: String, Codable, Hashable, Sendable {
    case unauthorized
    case invalidSignature
    case staleTimestamp
    case replayedNonce
    case unknownDevice
    case revokedDevice
    case unsupportedProtocolVersion
    case malformedPayload
    case sessionNotFound
    case approvalNotFound
    case approvalAlreadyDecided
    case approvalExpired
    case rateLimited
    case internalError
}

public struct RevokePayload: Codable, Hashable, Sendable {
    public let revokedDeviceId: UUID
    public let reason: String?
    public init(revokedDeviceId: UUID, reason: String? = nil) {
        self.revokedDeviceId = revokedDeviceId; self.reason = reason
    }
}

public struct ReconnectPayload: Codable, Hashable, Sendable {
    public let reason: String
    public let retryAfterSeconds: Int
    public init(reason: String, retryAfterSeconds: Int) {
        self.reason = reason; self.retryAfterSeconds = retryAfterSeconds
    }
}

public struct EmptyPayload: Codable, Hashable, Sendable { public init() {} }

// MARK: - Recent project list (iOS picker)

/// One entry in the list iOS shows in its project picker. Mirrors the Mac side's
/// `RecentProject` struct minus the SSH credential / git URL fields — those stay on the
/// Mac (iOS doesn't need them to ask the Mac to reopen the project; it just sends the
/// path back via `setProjectRootRequest`). The `kind` drives the icon in the iOS list
/// (folder / git / network).
public struct RecentProjectSummary: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let path: String
    public let kind: RecentProjectSummaryKind
    public let lastOpenedAt: Date?
    public init(id: String, displayName: String, path: String,
                kind: RecentProjectSummaryKind, lastOpenedAt: Date?) {
        self.id = id; self.displayName = displayName; self.path = path
        self.kind = kind; self.lastOpenedAt = lastOpenedAt
    }
}

public enum RecentProjectSummaryKind: String, Codable, Hashable, Sendable {
    case local
    case clone
    case ssh
}

/// iOS → Mac. No fields — the Mac responds with everything from `RecentProjectsService`.
public struct RecentProjectListRequestPayload: Codable, Hashable, Sendable {
    public let requestId: UUID
    public init(requestId: UUID = UUID()) { self.requestId = requestId }
}

/// Mac → iOS. Mirrors the Mac's local recents list at the moment of the request — a
/// snapshot, not a live subscription. The iOS picker re-fetches when the user re-enters
/// it (e.g. after the Mac opens a new project).
public struct RecentProjectListResponsePayload: Codable, Hashable, Sendable {
    public let requestId: UUID
    public let entries: [RecentProjectSummary]
    public init(requestId: UUID, entries: [RecentProjectSummary]) {
        self.requestId = requestId; self.entries = entries
    }
}
