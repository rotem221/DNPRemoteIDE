import Foundation

/// Parsing + formatting helpers for the inline "thinking" indicator on
/// the iOS chat surface. Lifted out of the app target so they can be
/// unit-tested without UI plumbing — the indicator's correctness
/// depends entirely on these pure transforms.
public enum ThinkingText {

    /// Format whole seconds as `Xh Ym Zs`, dropping zero-valued
    /// segments. Mirrors Claude's TUI status line shape:
    ///
    ///   45    → `45s`
    ///   125   → `2m 5s`
    ///   3725  → `1h 2m 5s`
    ///   3600  → `1h`
    ///   60    → `1m`
    ///
    /// Always emits at least one segment (so `formatElapsedHMS(0)`
    /// returns `0s` rather than an empty string).
    public static func formatElapsedHMS(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        let h = s / 3600
        let mTotal = s % 3600
        let m = mTotal / 60
        let r = mTotal % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if r > 0 || (h == 0 && m == 0) { parts.append("\(r)s") }
        return parts.joined(separator: " ")
    }

    /// Format an output-token count as `Nk` / `N.Nk` / `N.Nm` to
    /// match Claude's TUI shape (`↓ 3.7k tokens`).
    public static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fm", Double(n) / 1_000_000)
        }
        if n >= 1_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        }
        return "\(n)"
    }

    /// Pull Claude's currently-displayed rotating verb out of the
    /// live thinking text. Claude's TUI prints status lines shaped
    /// like `✻ Thinking…`, `✦ Crafting…`, `* Pondering…`. We scan
    /// each non-empty line for a leading capitalised word (4–16
    /// chars) sitting just before an ellipsis (`…` or `...`). The
    /// leading sparkle/marker char (if any) is skipped via
    /// `drop { !$0.isLetter }`. Returns nil when the line doesn't
    /// look like a status row so the caller falls back to the safe
    /// "Thinking" default.
    public static func extractClaudeVerb(from text: String) -> String? {
        let blacklist: Set<String> = [
            "User", "Claude", "Tool", "File", "Path", "Read", "Write", "Edit", "Bash",
            "The", "And", "But", "For", "With", "From", "Output", "Input"
        ]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let hasEllipsis = line.contains("…") || line.contains("...")
            guard hasEllipsis else { continue }
            let stripped = line.drop { !$0.isLetter }
            guard !stripped.isEmpty else { continue }
            let verb = String(stripped.prefix { $0.isLetter })
            guard verb.count >= 4, verb.count <= 16,
                  verb.first?.isUppercase == true,
                  !blacklist.contains(verb) else { continue }
            return verb
        }
        return nil
    }

    /// Returns the rest of Claude's visible TUI text below the verb
    /// status line — used to render the multi-line description that
    /// sits under the inline indicator. Skips the FIRST line that
    /// contains an ellipsis (the verb line itself, already shown by
    /// the indicator) and returns whatever comes after, trimmed.
    /// Drops todo-list rows (lines starting with checkbox glyphs)
    /// because TodoWrite events render as a dedicated card in the
    /// chat feed and shouldn't double-up in the inline description.
    /// Falls back to nil when there's nothing useful to surface.
    public static func descriptionExcludingVerb(from text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return nil }
        var skipIdx: Int? = nil
        for (i, line) in lines.enumerated() {
            if line.contains("…") || line.contains("...") {
                skipIdx = i
                break
            }
        }
        let remaining: ArraySlice<Substring>
        if let idx = skipIdx, idx + 1 < lines.count {
            remaining = lines[(idx + 1)...]
        } else if skipIdx == nil {
            remaining = lines[0...]
        } else {
            return nil
        }
        let filtered = remaining.filter { !isTodoLine($0) }
        let joined = filtered.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Heuristic: a line that begins (after any whitespace + a single
    /// optional `└` continuation glyph) with a checkbox / checkmark
    /// glyph is a TodoWrite row.
    public static func isTodoLine<S: StringProtocol>(_ line: S) -> Bool {
        let prefixGlyphs: Set<Character> = [
            "■", "□", "▣", "☐", "☑", "✓", "✗", "✔", "•", "●", "○"
        ]
        var seenContinuation = false
        for ch in line {
            if ch.isWhitespace { continue }
            if ch == "└" || ch == "├" || ch == "│" {
                if seenContinuation { return false }
                seenContinuation = true
                continue
            }
            return prefixGlyphs.contains(ch)
        }
        return false
    }
}
