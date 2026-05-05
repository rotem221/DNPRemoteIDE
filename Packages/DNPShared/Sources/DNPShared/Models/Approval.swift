import Foundation

public struct ApprovalRequest: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sessionId: UUID
    public let actionType: ApprovalActionType
    public let target: String              // command, file path, tool name, etc.
    public let summary: String
    public let detail: String?
    public let risk: RiskLevel
    public let requestedAt: Date
    public let timeoutAt: Date
    public var status: ApprovalStatus
    public var decidedAt: Date?
    public var decidedByDeviceId: UUID?

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        actionType: ApprovalActionType,
        target: String,
        summary: String,
        detail: String? = nil,
        risk: RiskLevel = .medium,
        requestedAt: Date = Date(),
        timeoutAt: Date,
        status: ApprovalStatus = .created,
        decidedAt: Date? = nil,
        decidedByDeviceId: UUID? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.actionType = actionType
        self.target = target
        self.summary = summary
        self.detail = detail
        self.risk = risk
        self.requestedAt = requestedAt.dnpQuantized
        self.timeoutAt = timeoutAt.dnpQuantized
        self.status = status
        self.decidedAt = decidedAt?.dnpQuantized
        self.decidedByDeviceId = decidedByDeviceId
    }
}

public enum ApprovalActionType: String, Codable, Hashable, Sendable {
    case bashCommand
    case fileWrite
    case fileEdit
    case fileDelete
    case mcpTool
    case webFetch
    case other
}

public enum ApprovalStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case created
    case sentToIOS
    case viewed
    case approved
    case rejected
    case expired
    case appliedToRuntime
    case failed
}

public struct ApprovalResponse: Codable, Hashable, Sendable {
    public let approvalId: UUID
    public let sessionId: UUID
    public let decision: ApprovalDecision
    public let deviceId: UUID
    public let decidedAt: Date
    public let comment: String?

    public init(
        approvalId: UUID,
        sessionId: UUID,
        decision: ApprovalDecision,
        deviceId: UUID,
        decidedAt: Date = Date(),
        comment: String? = nil
    ) {
        self.approvalId = approvalId
        self.sessionId = sessionId
        self.decision = decision
        self.deviceId = deviceId
        self.decidedAt = decidedAt.dnpQuantized
        self.comment = comment
    }
}

public enum ApprovalDecision: String, Codable, Hashable, Sendable {
    case approve
    case reject
}
