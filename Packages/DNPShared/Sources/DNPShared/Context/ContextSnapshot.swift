import Foundation

public struct ContextSnapshot: Codable, Hashable, Sendable {
    public let sessionId: UUID
    public let usedEstimate: Int?
    public let totalEstimate: Int?
    public let remainingEstimate: Int?
    public let percentRemaining: Double?
    public let health: ContextHealth
    public let confidence: ContextConfidence
    public let source: ContextSource
    public let updatedAt: Date
    public let warning: ContextWarning?
    /// Per-turn output tokens — Claude's `output_tokens` from the latest assistant message.
    /// Optional because the heuristic estimator can't compute it; populated only when the
    /// snapshot was built from `applyUsage` (real Claude metadata).
    public let lastTurnOutputTokens: Int?

    /// Inverse of `percentRemaining` (0.0 ... 1.0): the fraction of the
    /// context window already consumed. Most UI rings display this — it
    /// matches user intuition ("0% used at start, 100% used at full") and
    /// the visual fill (the ring grows as the session progresses, instead
    /// of shrinking). The data model still stores `percentRemaining` as the
    /// authoritative value because that's what the existing serialised
    /// snapshots / `lowContext` warnings are tied to; this is purely a
    /// derived view for presentation.
    public var percentUsed: Double? {
        guard let pct = percentRemaining else { return nil }
        return max(0, min(1, 1 - pct))
    }

    public init(
        sessionId: UUID,
        usedEstimate: Int? = nil,
        totalEstimate: Int? = nil,
        remainingEstimate: Int? = nil,
        percentRemaining: Double? = nil,
        health: ContextHealth = .unknown,
        confidence: ContextConfidence = .estimated,
        source: ContextSource = .heuristic,
        updatedAt: Date = Date(),
        warning: ContextWarning? = nil,
        lastTurnOutputTokens: Int? = nil
    ) {
        self.sessionId = sessionId
        self.usedEstimate = usedEstimate
        self.totalEstimate = totalEstimate
        self.remainingEstimate = remainingEstimate
        self.percentRemaining = percentRemaining
        self.health = health
        self.confidence = confidence
        self.source = source
        self.updatedAt = updatedAt.dnpQuantized
        self.warning = warning
        self.lastTurnOutputTokens = lastTurnOutputTokens
    }
}

public enum ContextHealth: String, Codable, Hashable, Sendable, CaseIterable {
    case healthy
    case moderate
    case low
    case critical
    case unknown

    /// Default ordering threshold from `percentRemaining`.
    public static func health(forPercent p: Double?) -> ContextHealth {
        guard let p = p else { return .unknown }
        switch p {
        case 0.50...:   return .healthy
        case 0.25..<0.50: return .moderate
        case 0.10..<0.25: return .low
        default:        return .critical
        }
    }
}

public enum ContextConfidence: String, Codable, Hashable, Sendable {
    case measured       // came from official Claude metadata
    case estimated      // computed from transcript heuristics
    case unknown
}

public enum ContextSource: String, Codable, Hashable, Sendable {
    case claudeMetadata
    case heuristic
    case compactionEvent
    case userOverride
}

public enum ContextWarning: String, Codable, Hashable, Sendable {
    case lowContext
    case sessionEndingSoon
    case compactionRecommended
    case parserUncertainty
}
