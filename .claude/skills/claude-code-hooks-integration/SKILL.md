---
name: claude-code-hooks-integration
description: Use when wiring or modifying Claude Code hooks — .claude/settings.json hook config, the dnp-hook-relay tool, mapping hook JSON to SessionEvent. Triggers on changes to .claude/settings.json or tools/dnp-hook-relay/.
---

## When to use

Anytime you add a hook event, change the relay's parsing, or update how Mac ingests hook JSON.

## Hard rules

- Use only documented events from `https://code.claude.com/docs/en/hooks`. Adding an undocumented event silently breaks.
- The relay (`tools/dnp-hook-relay`) is **fail-open** by default. Never make `--strict` the default.
- The relay POSTs to a localhost endpoint owned by Mac; on failure it appends to `.dnp/events/hooks.jsonl`. Mac ingests the fallback on next launch.
- Never have the relay block Claude on transport problems. Exit 0 unless explicitly strict.
- Hook commands in `.claude/settings.json` are run from the project directory — use `./tools/dnp-hook-relay/dnp-hook-relay` (relative).
- For events that allow blocking decisions (`PreToolUse`, `PermissionRequest`, `UserPromptSubmit`, `Stop`, `WorktreeCreate`), only emit `permissionDecision: "deny"` when the user already explicitly rejected via iOS — never on a guess.

## How to apply

### Settings entry

```json
"PreToolUse": [
  { "matcher": "*", "hooks": [
    { "type": "command", "command": "./tools/dnp-hook-relay/dnp-hook-relay --event PreToolUse" }
  ]}
]
```

### Relay envelope (per call)

```json
{
  "event": "PreToolUse",
  "timestamp": "2026-04-29T19:11:32.482Z",
  "cwd": "/Users/.../project",
  "pid": 12345,
  "raw": "{ ...stdin JSON from Claude... }"
}
```

### Common-fields shape Claude sends on stdin

```json
{
  "session_id": "abc123",
  "transcript_path": "/Users/.../<uuid>.jsonl",
  "cwd": "/Users/...",
  "permission_mode": "default",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_input": { "command": "npm test" }
}
```

### Mapping snippet (Mac side)

```swift
let typeMap: [String: SessionEventType] = [
    "SessionStart": .sessionStarted,
    "SessionEnd": .sessionEnded,
    "UserPromptSubmit": .userMessage,
    "PreToolUse": .toolActivity,
    "PostToolUse": .toolActivity,
    "PostToolUseFailure": .toolActivity,
    "PermissionRequest": .approvalRequired,
    "PermissionDenied": .approvalResult,
    "PreCompact": .compactStarted,
    "PostCompact": .compactCompleted,
    "Notification": .warning,
    "Stop": .sessionStatusUpdate,
    "SubagentStart": .subagentStarted,
    "SubagentStop": .subagentCompleted,
    "FileChanged": .fileChanged
]
```

### Decision JSON (only when user already rejected)

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "User rejected from DNP Remote iOS"
  }
}
```

## Examples

**Good** — POST first, fall back to JSONL:

```swift
if !tryPostToMac() { writeFallback() }
exit(args.failOpen ? 0 : (json.isEmpty ? 1 : 0))
```

**Bad** — failing closed by default:

```swift
exit(1)   // ❌ would brick Claude every time the Mac is offline
```

## Pitfalls

- Forgetting that not all events support `matcher` (e.g., `UserPromptSubmit`, `PostToolBatch`, `Stop`, `CwdChanged` ignore matchers).
- Mixing `if` filter and broad `matcher` — use one. The `if` filter uses permission-rule syntax (e.g., `Bash(git *)`).
- Long-running hook commands hit timeouts. Default is 600 s for command hooks; the relay finishes in < 2 s by design.
- Multiple hooks for the same event fire in order; if any returns exit 2, Claude treats it as a deny — keep our relay non-blocking.
