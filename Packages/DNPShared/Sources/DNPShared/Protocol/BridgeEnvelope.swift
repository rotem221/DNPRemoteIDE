import Foundation

/// Envelope wrapping every message on the local WebSocket bridge.
/// `signature` is computed by signing canonical JSON of the envelope with `signature == ""` over Ed25519.
public struct BridgeEnvelope<Payload: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public let id: UUID
    public let type: BridgeMessageType
    public let protocolVersion: Int
    public let senderId: UUID
    public let recipientId: UUID?
    public let sessionId: UUID?
    public let timestamp: Date
    public let nonce: String                 // base64, 16 bytes
    public var signature: String             // base64, 64 bytes (filled by signer)
    public let payload: Payload

    public init(
        id: UUID = UUID(),
        type: BridgeMessageType,
        protocolVersion: Int = ProtocolConstants.version,
        senderId: UUID,
        recipientId: UUID? = nil,
        sessionId: UUID? = nil,
        timestamp: Date = Date(),
        nonce: String,
        signature: String = "",
        payload: Payload
    ) {
        self.id = id
        self.type = type
        self.protocolVersion = protocolVersion
        self.senderId = senderId
        self.recipientId = recipientId
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.nonce = nonce
        self.signature = signature
        self.payload = payload
    }
}

public enum BridgeMessageType: String, Codable, Hashable, Sendable {
    case hello
    case helloAck
    case pairingRequest
    case pairingResponse
    case sessionListRequest
    case sessionListResponse
    case subscribeSession
    case unsubscribeSession
    case eventBatch
    case liveEvent
    case userPrompt
    case approvalResponse
    case newSessionRequest
    case closeSessionRequest          // iOS → Mac: end the named session (calls confirmClose)
    case attachmentTransfer
    case cancelRunning
    case projectInfo                  // Mac → iOS: which folder is currently the active project
    case openFolderRequest            // iOS → Mac: open NSOpenPanel and adopt the chosen folder
    case directoryListingRequest      // iOS → Mac: ls one directory inside the active project
    case directoryListingResponse     // Mac → iOS: results of the above
    case fileContentRequest           // iOS → Mac: read a file's bytes
    case fileContentResponse          // Mac → iOS: file bytes (UTF-8 text or base64 binary)
    case fileWriteRequest             // iOS → Mac: save edited text to a file
    case fileWriteResponse            // Mac → iOS: ack/error for the save
    case fileSearchRequest            // iOS → Mac: recursive name+content search
    case fileSearchResponse           // Mac → iOS: search results
    case setProjectRootRequest        // iOS → Mac: adopt this absolute path as project root
    case githubRepoListRequest        // iOS → Mac: list user's GitHub repos via `gh repo list`
    case githubRepoListResponse       // Mac → iOS: list of repos
    case githubAdoptRepoRequest       // iOS → Mac: clone if needed and adopt as project
    case recentProjectListRequest     // iOS → Mac: list local/clone/ssh recent projects
    case recentProjectListResponse    // Mac → iOS: the list, with kind icon hints
    case screenMirrorStart            // iOS → Mac: start streaming screen frames
    case screenMirrorStop             // iOS → Mac: stop streaming
    case screenMirrorFrame            // Mac → iOS: one captured frame (JPEG, base64)
    case screenMirrorCursor           // Mac → iOS: cursor position update (decoupled from frames so the cursor can stream at ~30Hz while frames stay at 5–10fps)
    case remoteInput                  // iOS → Mac: synthesised mouse/keyboard event
    case forceApprove                 // iOS → Mac: user-driven "type 1\r into the named session's PTY now" — escape hatch when our PTY-driven approval detection misses a prompt
    case aiUsageBroadcast             // Mac → iOS: latest Claude Code usage snapshot (5h / 7d / etc. quotas) for the Context popover
    case activeSessionBroadcast       // Mac → iOS: id of the IDE's currently-focused session (drives auto-follow on the iOS session capsule)
    case heartbeat
    case reconnect
    case revoke
    case error
}

public enum ProtocolConstants {
    public static let version: Int = 1
    public static let maxClockSkewSeconds: TimeInterval = 60
    public static let maxNonceCacheSize: Int = 4096
    public static let heartbeatIntervalSeconds: TimeInterval = 15
    public static let heartbeatTimeoutSeconds: TimeInterval = 45
    public static let approvalDefaultTimeoutSeconds: TimeInterval = 5 * 60
    public static let eventBackfillBatchSize: Int = 200
}
