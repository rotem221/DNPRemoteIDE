import Foundation

/// Heuristic context-budget estimator used when official Claude metadata isn't available.
/// Approximates "tokens used" from transcript bytes (≈ 4 bytes per token in English text;
/// chunkier for code). Caller should label the resulting snapshot as `.estimated`.
public struct ContextEstimator: Sendable {
    public let bytesPerToken: Double
    public let totalTokenBudget: Int

    public init(bytesPerToken: Double = 3.8, totalTokenBudget: Int = 200_000) {
        // Default budget aligns with Claude Code's standard 200K context window for
        // Sonnet/Opus default tiers — the same denominator the model-specific budget
        // picker uses on Mac when the transcript's `usage` block lands. Keeping the
        // heuristic and the measurement on the same denominator means a brand-new
        // session reads a sensible "near 100% remaining" out of 200K, and the value
        // does NOT jump dramatically the first time Claude reports usage. Opus 4.x
        // 1M-beta sessions are auto-detected upstream by `MacAppViewModel.resolveBudget`
        // when the observed used count exceeds 200K, so picking 200K as the default
        // here doesn't cap users on the larger window.
        self.bytesPerToken = bytesPerToken
        self.totalTokenBudget = totalTokenBudget
    }

    public func snapshot(
        sessionId: UUID,
        transcriptBytes: Int,
        eventCount: Int,
        compactionCount: Int = 0,
        confidence: ContextConfidence = .estimated,
        source: ContextSource = .heuristic
    ) -> ContextSnapshot {
        let used = max(0, Int(Double(transcriptBytes) / bytesPerToken)
                          - compactionCount * Int(0.6 * Double(totalTokenBudget))) // compaction frees ~60%
        let remaining = max(0, totalTokenBudget - used)
        let percent = Double(remaining) / Double(totalTokenBudget)
        let health = ContextHealth.health(forPercent: percent)
        var warning: ContextWarning? = nil
        switch health {
        case .low: warning = .lowContext
        case .critical: warning = .sessionEndingSoon
        default: break
        }
        if eventCount > 800 && health == .moderate {
            warning = .compactionRecommended
        }
        return ContextSnapshot(
            sessionId: sessionId,
            usedEstimate: used,
            totalEstimate: totalTokenBudget,
            remainingEstimate: remaining,
            percentRemaining: percent,
            health: health,
            confidence: confidence,
            source: source,
            warning: warning
        )
    }
}
