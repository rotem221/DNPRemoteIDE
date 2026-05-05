---
name: local-persistence-and-recovery
description: Use when changing how sessions are persisted, how transcripts/JSONL evolve, how summaries are generated, how recovery on relaunch works, how the per-project memory/MEMORY.md is maintained, or how crashes are captured. Triggers on changes to apps/DNPRemoteMac/DNPRemoteMac/Persistence/ or Diagnostics/CrashReporter.swift.
---

## When to use

Anytime you persist, restore, or summarize session data — and anytime you build or change the long-term project notebook.

## Hard rules

- Canonical session layout: `memory/sessions/{id}/events.jsonl`, `transcript.md`, `summary.md`, `metadata.json`. Don't rename these four.
- `events.jsonl` is **append-only**. No rewrites. Use a sibling `events.archive-<ts>.jsonl` if you must compact.
- `transcript.md` is rendered via `MarkdownTranscript.render`. Don't open-code the format here.
- Project notebook lives at `<projectPath>/memory/MEMORY.md` (index) plus `<projectPath>/memory/notes/*.md`. Index lines ≤ 150 chars: `- [Title](notes/file.md) — date`.
- Crash reports: `memory/crashes/<ISO-ts>-<uuid>.json` with `kind`, `message`, optional `stackTrace`, optional `sessionId`, environment.
- On relaunch: sessions whose `status == .running` whose PTY child is gone become `.crashed`, and a `.crash` event is appended.

## How to apply

### Append an event durably

```swift
func appendEvent(_ event: SessionEvent) async {
    let dir = sessionDir(event.sessionId)
    if let data = try? DNPCoders.encode(event) {
        let line = data + Data([0x0A])
        let url = dir.appendingPathComponent("events.jsonl")
        if FileManager.default.fileExists(atPath: url.path) {
            if let h = try? FileHandle(forWritingTo: url) {
                try? h.seekToEnd(); try? h.write(contentsOf: line); try? h.close()
            }
        } else {
            try? line.write(to: url)
        }
    }
    appendMarkdown(event, to: dir.appendingPathComponent("transcript.md"))
}
```

### Project notebook — append a note

```swift
func appendNote(projectPath: String, title: String, body: String, tags: [String]) async throws -> URL {
    let stamp = fileStamp(Date())
    let slug  = slugify(title)
    let url = memoryRoot(for: projectPath).appendingPathComponent("notes/\(stamp)-\(slug).md")
    var md = "# \(title)\n\n*captured:* \(ISO8601DateFormatter.dnpShared.string(from: Date()))\n"
    if !tags.isEmpty { md += "*tags:* \(tags.joined(separator: ", "))\n" }
    md += "\n---\n\n\(body)\n"
    try md.data(using: .utf8)!.write(to: url)
    try await rebuildIndex(projectPath: projectPath)
    return url
}
```

### Crash capture

```swift
func recordRecoverable(kind: CrashKind, sessionId: UUID?, message: String, stack: String? = nil) {
    let report = CrashReport(sessionId: sessionId, kind: kind, message: message, stackTrace: stack)
    let stamp = ISO8601DateFormatter.dnpShared.string(from: report.timestamp).replacingOccurrences(of: ":", with: "-")
    let url = crashesDir.appendingPathComponent("\(stamp)-\(report.id.uuidString).json")
    if let data = try? DNPCoders.encode(report) { try? data.write(to: url) }
    Task { await appendEvent(SessionEvent(sessionId: sessionId ?? UUID(), sequence: 0, type: .crash,
                                          severity: .critical, source: .system,
                                          title: "Crash: \(kind.rawValue)",
                                          summary: message,
                                          payload: .crash(CrashPayload(kind: kind, message: message,
                                                                       stackTracePreview: stack?.prefix(2000).asString,
                                                                       reportPath: url.path)))) }
}
```

### Recovery on relaunch

```swift
let metas = try fm.contentsOfDirectory(at: memoryRoot.appendingPathComponent("sessions"), …)
for url in metas {
    if let data = try? Data(contentsOf: url.appendingPathComponent("metadata.json")),
       var session = try? DNPCoders.decode(Session.self, from: data) {
        if session.status == .running, !ProcessInfo.isPidAlive(session.pid) {
            session.status = .crashed
            crashes.recordRecoverable(.ptyExitedUnexpectedly, sessionId: session.id, message: "Mac restarted")
        }
        try await sessions.upsert(session)
    }
}
```

## Examples

**Good** — JSONL append never rewrites:

```swift
let h = try FileHandle(forWritingTo: url)
try h.seekToEnd()
try h.write(contentsOf: line)
```

**Bad** — rewriting the whole file every event:

```swift
try line.write(to: url, options: .atomic)   // ❌ truncates everything
```

## Pitfalls

- `FileHandle.seekToEnd()` and `write(contentsOf:)` are the modern API; older `seek(toFileOffset:)` lacks Swift error throwing.
- Forgetting to create the parent directory on first write — every persistence call should `createDirectory(withIntermediateDirectories: true)`.
- Treating `MEMORY.md` as a free-form file. It's an *index* — bodies live in `notes/`. Keep entries one line.
- Crash handlers re-entering during a Swift uncaught exception. `CrashReporter.installSignalHandlers()` is idempotent.
