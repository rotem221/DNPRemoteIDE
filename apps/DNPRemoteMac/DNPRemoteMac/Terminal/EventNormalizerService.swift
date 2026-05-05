import Foundation

/// Converts raw PTY bytes + hook JSON + lifecycle signals into clean `SessionEvent`s.
final class EventNormalizerService: @unchecked Sendable {

    private let lock = NSLock()
    private var sequencePerSession: [UUID: UInt64] = [:]
    private var ansiBuffer: [UUID: String] = [:]
    private var commandFrames: [UUID: CommandFrame] = [:]

    /// Push raw PTY bytes; returns 0+ semantic events.
    func ingest(rawPTY data: Data, sessionId: UUID) -> [SessionEvent] {
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        lock.lock()
        let pending = ansiBuffer[sessionId, default: ""] + s
        // Process complete lines only; carry partial tail.
        let parts = pending.components(separatedBy: "\n")
        let complete = parts.dropLast()
        let tail = parts.last ?? ""
        ansiBuffer[sessionId] = tail
        lock.unlock()
        var events: [SessionEvent] = []
        for raw in complete {
            let cleaned = ANSICleaner.clean(String(raw))
            if cleaned.isEmpty { continue }
            if let event = detectCommand(line: cleaned, sessionId: sessionId) {
                events.append(event)
                continue
            }
            // Default: append as command output if there's an open frame, else suppress.
            if commandFrames[sessionId] != nil {
                let summary = String(cleaned.prefix(240))
                events.append(make(sessionId: sessionId, type: .commandOutput, severity: .debug,
                                   source: .parser, title: "Output", summary: summary))
            }
        }
        return events
    }

    /// Push a Claude Code hook JSON payload; map to event(s).
    func ingest(hookEvent name: String, json: String, sessionId: UUID) -> [SessionEvent] {
        let typeMap: [String: SessionEventType] = [
            "SessionStart": .sessionStarted,
            "SessionEnd": .sessionEnded,
            "UserPromptSubmit": .userMessage,
            "PreToolUse": .toolActivity,
            "PostToolUse": .toolActivity,
            "Notification": .warning,
            "PreCompact": .compactStarted,
            "PostCompact": .compactCompleted,
            "Stop": .sessionStatusUpdate,
            "SubagentStop": .subagentCompleted
        ]
        let type = typeMap[name] ?? .unknown
        let raw = RawPayload(kind: name, json: json)
        return [make(
            sessionId: sessionId,
            type: type,
            severity: type == .warning ? .warning : .info,
            source: .hookRelay,
            title: name,
            summary: nil,
            payload: .raw(raw)
        )]
    }

    // MARK: - Helpers

    private struct CommandFrame {
        let command: String
        let startedAt: Date
    }

    private func detectCommand(line: String, sessionId: UUID) -> SessionEvent? {
        // Heuristic: lines that begin with `$ ` or `> ` are command echoes.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("$ ") || trimmed.hasPrefix("> ") {
            let cmd = String(trimmed.dropFirst(2))
            commandFrames[sessionId] = CommandFrame(command: cmd, startedAt: Date())
            let payload = CommandEventPayload(
                command: cmd,
                risk: RiskClassifier.risk(forBash: cmd),
                status: .running
            )
            return make(sessionId: sessionId, type: .commandStarted, severity: .info,
                        source: .parser, title: "Running: \(cmd)", payload: .command(payload))
        }
        return nil
    }

    private func nextSequence(for sessionId: UUID) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let next = (sequencePerSession[sessionId] ?? 0) + 1
        sequencePerSession[sessionId] = next
        return next
    }

    private func make(
        sessionId: UUID,
        type: SessionEventType,
        severity: SessionEventSeverity,
        source: SessionSource,
        title: String,
        summary: String? = nil,
        payload: SessionEventPayload? = nil
    ) -> SessionEvent {
        SessionEvent(
            sessionId: sessionId,
            sequence: nextSequence(for: sessionId),
            type: type,
            severity: severity,
            source: source,
            title: title,
            summary: summary,
            payload: payload
        )
    }
}
