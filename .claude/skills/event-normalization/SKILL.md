---
name: event-normalization
description: Use when modifying the pipeline that turns raw bytes + hook JSON + lifecycle signals into clean SessionEvent — ANSI cleaning, noise filtering, command/code-edit/tool detectors, dedup, severity tagging. Triggers on changes to apps/DNPRemoteMac/DNPRemoteMac/Terminal/EventNormalizerService.swift or DNPShared/Utilities/ANSI.swift / RiskClassifier.swift.
---

## When to use

The single most important skill in the suite. Get this wrong and iOS shows garbage; get this right and the rest of the product feels effortless.

## Hard rules

- Inputs: PTY bytes (UTF-8), hook JSON, command lifecycle signals, file watcher events. Outputs: `[SessionEvent]`.
- Always run `ANSICleaner.clean` before line-level matching. Never assume bytes are already clean.
- Sequence numbers per session must be **monotonic**. Use `nextSequence(for: sessionId)`; never reset mid-session.
- Risk classification: route through `RiskClassifier.risk(forBash:)` / `risk(forFileWrite:)`. Don't open-code keyword lists.
- Don't speculate Claude's voice. `.assistantMessage` only comes from a hook signal — never from PTY parsing.
- Idempotency: if the same hook JSON shows up twice (relay retry + Mac cache replay), emit at most one event. Use `(event_name, session_id, payload-hash)` for dedup.
- Severity tagging: `.warning`/`.error` only when there is a concrete reason. Default `.info`.

## How to apply

### Pipeline

```
PTY bytes ─▶ ANSICleaner.clean
          ─▶ collapseCarriageReturns (if line had multiple \r)
          ─▶ noise filter (drop empty lines, prompt echo)
          ─▶ event detector (commandStarted, commandCompleted, codeEdit fallback)
          ─▶ EventNormalizer.make(...)
hook JSON ─▶ HookRelaySink.parse
          ─▶ map hook_event_name → SessionEventType
          ─▶ EventNormalizer.make(...)
```

### Command detection

```swift
func detectCommand(line: String, sessionId: UUID) -> SessionEvent? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("$ ") || trimmed.hasPrefix("> ") else { return nil }
    let cmd = String(trimmed.dropFirst(2))
    commandFrames[sessionId] = CommandFrame(command: cmd, startedAt: Date())
    let payload = CommandEventPayload(command: cmd,
                                      risk: RiskClassifier.risk(forBash: cmd),
                                      status: .running)
    return make(... type: .commandStarted, payload: .command(payload))
}
```

### Code edit detection (post-tool-use)

When `PostToolUse` arrives for `Edit` / `Write` / `MultiEdit`:

```swift
let payload = CodeEditPayload(
    filePath: toolInput.file_path,
    changeKind: detectKind(toolInput),
    linesAdded: countAdded(toolResponse.diff),
    linesRemoved: countRemoved(toolResponse.diff),
    summary: humanSummary(toolInput, toolResponse),
    diffPreview: toolResponse.diff?.prefix(2000).asString
)
emit(.codeEditSummary, .codeEdit(payload))
```

### Dedup

```swift
let key = "\(name)|\(sessionId)|\(stableHash(json))"
guard !recentlySeen.contains(key) else { return [] }
recentlySeen.insert(key)
```

## Examples

**Good** — single typed event for a recognized line:

```
$ npm install
```

→ One `.commandStarted` with `CommandEventPayload(command: "npm install", risk: .medium)`.

**Bad** — emitting both an `.unknown` and a `.commandStarted` for the same line:

```swift
events.append(makeUnknown(line))         // ❌
events.append(makeCommand(line))         // ❌
```

## Pitfalls

- Partial UTF-8 sequences split across reads. Buffer the trailing bytes and prepend on next chunk (we already do this in `ansiBuffer`).
- Lines that are just `\r` overwrites (spinners). `collapseCarriageReturns` handles them; don't re-implement.
- Treating ANSI bracketed paste as user input. Strip in `ANSICleaner.clean`.
- Emitting too-noisy `.commandOutput` events. Only emit when there's a meaningful signal (errors, summary lines), or when in Mac developer-detail mode.
- Pinning the JSON shape of `tool_response`. Different tools shape it differently — defensive optional decoding.
