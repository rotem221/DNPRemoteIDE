import Foundation

/// Renders a single `SessionEvent` as a Markdown chunk. Used by the persistence layer
/// to grow `memory/sessions/{id}/transcript.md` over time.
public enum MarkdownTranscript {
    public static func render(_ e: SessionEvent) -> String {
        let ts = ISO8601DateFormatter.dnpShared.string(from: e.timestamp)
        var out = "### `\(ts)` — \(humanType(e.type))\n"
        out += "*severity:* `\(e.severity.rawValue)` · *source:* `\(e.source.rawValue)`\n\n"
        out += "**\(e.title)**\n\n"
        if let s = e.summary { out += "\(s)\n\n" }
        if let payload = e.payload {
            out += renderPayload(payload)
        }
        out += "\n---\n"
        return out
    }

    private static func humanType(_ t: SessionEventType) -> String {
        switch t {
        case .userMessage: return "User"
        case .assistantMessage: return "Assistant"
        case .thinkingSummary: return "Thinking"
        case .commandStarted: return "Command started"
        case .commandOutput: return "Command output"
        case .commandCompleted: return "Command completed"
        case .codeEditSummary: return "Code edit"
        case .fileChanged: return "File changed"
        case .toolActivity: return "Tool"
        case .approvalRequired: return "Approval required"
        case .approvalResult: return "Approval result"
        case .warning: return "Warning"
        case .error: return "Error"
        case .contextUpdate: return "Context"
        case .sessionStatusUpdate: return "Status"
        case .sessionStarted: return "Session started"
        case .sessionEnded: return "Session ended"
        case .compactStarted: return "Compaction started"
        case .compactCompleted: return "Compaction completed"
        case .subagentStarted: return "Subagent started"
        case .subagentCompleted: return "Subagent completed"
        case .crash: return "Crash"
        case .unknown: return "Unknown"
        }
    }

    private static func renderPayload(_ p: SessionEventPayload) -> String {
        switch p {
        case .command(let c):
            var out = "```sh\n\(c.command)\n```\n"
            if let cwd = c.workingDirectory { out += "*cwd:* `\(cwd)`  \n" }
            out += "*risk:* `\(c.risk.rawValue)`  ·  *status:* `\(c.status.rawValue)`"
            if let d = c.durationMs { out += "  ·  *duration:* `\(d) ms`" }
            if let exit = c.exitCode { out += "  ·  *exit:* `\(exit)`" }
            out += "\n\n"
            if let s = c.outputSummary { out += "Output: \(s)\n\n" }
            return out
        case .codeEdit(let e):
            var out = "📄 `\(e.filePath)` — \(e.changeKind.rawValue)\n\n"
            out += "+\(e.linesAdded) / -\(e.linesRemoved)\n\n"
            out += "\(e.summary)\n\n"
            if let diff = e.diffPreview { out += "```diff\n\(diff)\n```\n\n" }
            return out
        case .fileChanged(let f):
            return "📁 `\(f.path)` — \(f.operation.rawValue)\n\n"
        case .toolActivity(let t):
            return "🔧 \(t.toolName) (\(t.provider.rawValue)) — \(t.status.rawValue)\n\n"
        case .approval(let a):
            return "🛡️ Approval `\(a.approvalId)` — \(a.lifecycle.rawValue): \(a.actionSummary)\n\n"
        case .context(let s):
            let pct = s.percentRemaining.map { String(format: "%.1f%%", $0 * 100) } ?? "?"
            return "📊 Context: \(pct) remaining (\(s.health.rawValue), \(s.confidence.rawValue))\n\n"
        case .message(let m):
            return "> **\(m.role.rawValue)**: \(m.text)\n\n"
        case .warning(let w):
            return "⚠️ **\(w.title)**\(w.detail.map { ": \($0)" } ?? "")\n\n"
        case .error(let er):
            return "❌ **\(er.title)**\(er.detail.map { ": \($0)" } ?? "")\n\n"
        case .crash(let cr):
            return "💥 **Crash:** \(cr.kind.rawValue) — \(cr.message)\n\n"
        case .subagent(let sa):
            return "🤖 Subagent `\(sa.subagentName)` — \(sa.status.rawValue)\n\n"
        case .raw(let r):
            return "_(raw \(r.kind))_\n\n"
        }
    }
}
