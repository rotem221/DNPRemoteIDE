import Foundation

/// One usage window inside Claude Code's `/api/oauth/usage` response — `5h`,
/// `7d`, `7d Sonnet`, `7d Omelette`. Mirrors the shape Muxy parses from the
/// same endpoint, narrowed to just the fields our UI needs.
public struct AIUsageWindow: Codable, Hashable, Sendable {
    /// Short label as rendered in the UI ("5h", "7d", etc.).
    public let label: String
    /// 0–100 percent utilised. `nil` when the endpoint omits a window.
    public let percent: Double?
    /// When this window resets (Anthropic ships ISO-8601 with offset).
    public let resetAt: Date?
    /// Pre-formatted detail string — e.g. `"40.0% used"`.
    public let detail: String?

    public init(label: String, percent: Double?, resetAt: Date?, detail: String?) {
        self.label = label
        self.percent = percent
        self.resetAt = resetAt
        self.detail = detail
    }
}

/// Snapshot of the AI usage indicator the Mac displays at the bottom of the
/// IDE and broadcasts to the iOS Context popover. `errorMessage` non-nil
/// means we couldn't fetch (no token, expired, network down, etc.) — the UI
/// shows that string verbatim and falls back to "Sign in" guidance.
public struct AIUsageSnapshot: Codable, Hashable, Sendable {
    public let providerName: String
    public let fetchedAt: Date
    public let windows: [AIUsageWindow]
    public let errorMessage: String?

    public init(providerName: String,
                fetchedAt: Date,
                windows: [AIUsageWindow],
                errorMessage: String?) {
        self.providerName = providerName
        self.fetchedAt = fetchedAt
        self.windows = windows
        self.errorMessage = errorMessage
    }
}
