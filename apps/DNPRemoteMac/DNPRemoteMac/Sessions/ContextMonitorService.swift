import Foundation

actor ContextMonitorService {

    private var transcriptBytes: [UUID: Int] = [:]
    private var eventCount: [UUID: Int] = [:]
    private var compactionCount: [UUID: Int] = [:]
    private var lastSnapshot: [UUID: ContextSnapshot] = [:]

    private let estimator = ContextEstimator()

    func observe(_ event: SessionEvent) -> ContextSnapshot? {
        eventCount[event.sessionId, default: 0] += 1
        switch event.type {
        case .compactCompleted: compactionCount[event.sessionId, default: 0] += 1
        case .userMessage, .assistantMessage, .commandOutput, .codeEditSummary:
            transcriptBytes[event.sessionId, default: 0] += event.summary?.utf8.count ?? 0
                + event.title.utf8.count
        default: break
        }
        let snap = estimator.snapshot(
            sessionId: event.sessionId,
            transcriptBytes: transcriptBytes[event.sessionId] ?? 0,
            eventCount: eventCount[event.sessionId] ?? 0,
            compactionCount: compactionCount[event.sessionId] ?? 0
        )
        if let prev = lastSnapshot[event.sessionId], prev.health == snap.health, prev.warning == snap.warning {
            // Suppress duplicate snapshots; only emit on health/warning change.
            return nil
        }
        lastSnapshot[event.sessionId] = snap
        return snap
    }

    func current(for sessionId: UUID) -> ContextSnapshot? { lastSnapshot[sessionId] }
}
