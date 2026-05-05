import Foundation

actor ApprovalCoordinator {

    private var pending: [UUID: ApprovalRequest] = [:]
    private(set) var auditLog: [ApprovalAuditEntry] = []

    struct ApprovalAuditEntry: Codable, Sendable {
        let approvalId: UUID
        let lifecycle: ApprovalLifecycle
        let timestamp: Date
        let actorDeviceId: UUID?
        let note: String?
    }

    func create(_ request: ApprovalRequest) {
        pending[request.id] = request
        record(request.id, .requested, nil, "created")
    }

    func markSentToIOS(_ id: UUID) {
        update(id) { $0.status = .sentToIOS }
        record(id, .sentToIOS, nil, nil)
    }

    func markViewed(_ id: UUID, by deviceId: UUID) {
        update(id) { $0.status = .viewed }
        record(id, .viewed, deviceId, nil)
    }

    func apply(_ response: ApprovalResponse) -> ApplyResult {
        guard var existing = pending[response.approvalId] else { return .notFound }
        if existing.status == .approved || existing.status == .rejected {
            return .alreadyDecided(existing.status)
        }
        if Date() > existing.timeoutAt {
            existing.status = .expired
            pending[existing.id] = existing
            record(existing.id, .expired, response.deviceId, "auto-expired before apply")
            return .expired
        }
        existing.status = response.decision == .approve ? .approved : .rejected
        existing.decidedAt = response.decidedAt
        existing.decidedByDeviceId = response.deviceId
        pending[existing.id] = existing
        record(existing.id, response.decision == .approve ? .approved : .rejected,
               response.deviceId, response.comment)
        return .accepted(existing)
    }

    func markAppliedToRuntime(_ id: UUID) {
        update(id) { $0.status = .appliedToRuntime }
        record(id, .appliedToRuntime, nil, nil)
    }

    func markFailed(_ id: UUID, reason: String) {
        update(id) { $0.status = .failed }
        record(id, .failed, nil, reason)
    }

    func snapshot() -> [ApprovalRequest] { Array(pending.values).sorted { $0.requestedAt < $1.requestedAt } }

    enum ApplyResult: Sendable {
        case accepted(ApprovalRequest)
        case notFound
        case alreadyDecided(ApprovalStatus)
        case expired
    }

    private func update(_ id: UUID, _ mutator: (inout ApprovalRequest) -> Void) {
        guard var x = pending[id] else { return }
        mutator(&x); pending[id] = x
    }

    private func record(_ id: UUID, _ lc: ApprovalLifecycle, _ deviceId: UUID?, _ note: String?) {
        auditLog.append(ApprovalAuditEntry(approvalId: id, lifecycle: lc, timestamp: Date(), actorDeviceId: deviceId, note: note))
    }
}
