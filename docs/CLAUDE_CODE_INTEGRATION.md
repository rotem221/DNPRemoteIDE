# Claude Code Integration — DNP Remote Suite

This is the canonical reference for how DNP Remote Mac talks to Claude Code. We use **only** documented, supported surfaces. We never reverse-engineer Claude's private remote-control protocol; we never default to permission bypass.

> Source of truth as of 2026-04-29: `https://code.claude.com/docs/en/hooks` and the surrounding `code.claude.com/docs/en/*` pages. The legacy `docs.claude.com/en/docs/claude-code/*` URLs now redirect to `code.claude.com/docs/en/*`. Where this doc claims a behavior, it cites the page or marks the claim `*assumption*` so reviewers can verify.

## 1. Integration surfaces (in / out)

| Surface | We use it? | Notes |
|---|---|---|
| `claude` CLI (interactive) | ✅ launch inside PTY | Real terminal required. |
| `claude --print` (non-interactive) | ⚠️ optional | We prefer the interactive flow so hooks/permissions behave naturally. |
| `.claude/settings.json` hooks | ✅ primary integration | See §2. |
| `.claude/settings.local.json` | ✅ user-only overrides | Never committed. Gitignored. |
| Permissions (`ask` / `allow` / `deny`, `permissionDecision`) | ✅ respected | Approvals on iOS map to real Claude permission events. |
| MCP servers (`.mcp.json`) | ✅ surface activity | Tool calls render as cards on iOS. We don't run MCP ourselves; we just observe. |
| Subagents (`.claude/agents/`) | ✅ defined for *this* repo | We surface SubagentStart/Stop events to iOS. |
| Slash commands | ✅ pass-through | UserPromptExpansion hook tells us when one fires. |
| Memory files (`CLAUDE.md`, `.claude/rules/*.md`) | ✅ honored | InstructionsLoaded hook tells us which were picked up. |
| Private Claude remote-control APIs | ❌ never | Out of scope. Forbidden. |
| `--dangerously-skip-permissions` | ❌ never default | Available behind an explicit Mac toggle, but iOS never grants it. |

## 2. Hook events — definitive list

The Claude Code docs list the events below. We relay each one through `tools/dnp-hook-relay/` into our `EventNormalizerService`. Events not yet shipped in the installed Claude version simply never fire — the relay is fail-open and degrades silently.

| Event | When it fires | Maps to our `SessionEventType` | Blocking? (exit 2) |
|---|---|---|---|
| `SessionStart` | Session begins or resumes | `.sessionStarted` | no |
| `Setup` | `--init`/`--maintenance` invocations | `.sessionStatusUpdate` | no |
| `UserPromptSubmit` | User submits a prompt | `.userMessage` | yes — blocks prompt |
| `UserPromptExpansion` | Slash command expands | `.toolActivity` (subkind: slash command) | yes |
| `PreToolUse` | Before a tool call | `.toolActivity` + (if risky) `.approvalRequired` | yes — blocks call |
| `PermissionRequest` | Permission dialog appears | `.approvalRequired` | yes — denies if exit 2 |
| `PermissionDenied` | Auto-mode denial | `.approvalResult` (decision = reject) | n/a |
| `PostToolUse` | Tool call success | `.toolActivity` (status = completed) + `.codeEditSummary` / `.fileChanged` if applicable | no |
| `PostToolUseFailure` | Tool call failure | `.toolActivity` (status = failed) + `.warning` | no |
| `PostToolBatch` | Parallel batch resolved | `.toolActivity` (batch summary) | yes — stops next model call |
| `Notification` | Claude emits a notification | `.warning` | no |
| `SubagentStart` | Subagent spawned | `.subagentStarted` | no |
| `SubagentStop` | Subagent finished | `.subagentCompleted` | no |
| `TaskCreated` / `TaskCompleted` | TodoWrite-style tasks | `.toolActivity` | no |
| `Stop` | Claude finished a turn | `.sessionStatusUpdate` (waiting-for-user) | yes — keeps Claude going |
| `StopFailure` | Turn ended on API error | `.error` | no |
| `TeammateIdle` | Team teammate idle | `.sessionStatusUpdate` | no |
| `InstructionsLoaded` | CLAUDE.md / `.claude/rules/*.md` loaded | `.toolActivity` (debug) | no |
| `ConfigChange` | Config changed mid-session | `.warning` | no |
| `CwdChanged` | Working directory changed | `.warning` | no |
| `FileChanged` | Watched file changed on disk | `.fileChanged` | no |
| `WorktreeCreate` / `WorktreeRemove` | Worktree lifecycle | `.toolActivity` | yes (Create) |
| `Elicitation` / `ElicitationResult` | MCP server requested user input | `.approvalRequired` / `.approvalResult` | yes |
| `PreCompact` | Before compaction | `.compactStarted` + `.warning` (compactionRecommended) | no |
| `PostCompact` | After compaction | `.compactCompleted` + `.contextUpdate` | no |
| `SessionEnd` | Session terminates | `.sessionEnded` | no |

### Hook stdin envelope

Every hook command receives a JSON payload on stdin with these common fields:

```json
{
  "session_id": "abc123",
  "transcript_path": "/Users/.../.claude/projects/.../<uuid>.jsonl",
  "cwd": "/Users/...",
  "permission_mode": "default",
  "hook_event_name": "PreToolUse"
}
```

Event-specific keys layer on top (e.g., `tool_name`, `tool_input`, `prompt`, `permission_suggestions`, `source`, `trigger`, `file_path`, `memory_type`, `load_reason`). Our normalizer captures `hook_event_name` first, then dispatches to a per-event handler.

### Hook configuration shape

Our `.claude/settings.json` registers `command`-type hooks pointing at `tools/dnp-hook-relay/dnp-hook-relay --event <Name>`. Each entry's `matcher` is the empty/`"*"` form, so the relay receives every occurrence; matcher-based filtering happens inside the normalizer. We use the field set documented for command hooks:

```json
{
  "type": "command",
  "command": "./tools/dnp-hook-relay/dnp-hook-relay --event PreToolUse",
  "timeout": 600,
  "shell": "bash"
}
```

Documented hook-handler types we deliberately do **not** use in the default profile:
- `http` — would let Claude POST directly to Mac. Same effect as our command relay; we keep one path to audit. Could be enabled by power users.
- `mcp_tool` — too tightly coupled to a specific server.
- `prompt` / `agent` — out of scope for relay; valuable for project-side rules.

### Exit codes & blocking

We treat exit codes per the docs:

| Exit | Behavior |
|---|---|
| 0 | Success. Stdout JSON (if any) is parsed by Claude Code for decisions. |
| 2 | Blocking error. Stderr is fed back to Claude. Effect depends on event. |
| other | Non-blocking. Stderr shown in transcript. |

`dnp-hook-relay` is **fail-open** by default (`exit 0`) — we never want a transient bridge problem to brick the user's Claude session. Strict mode (`--strict`) is available for power users who want denials to actually deny.

### Decision JSON

When we *do* want to influence Claude (e.g., a user rejected an iOS approval before the timeout), the relay can emit:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "User rejected from DNP Remote iOS"
  }
}
```

`permissionDecision` precedence per docs: `deny > defer > ask > allow`.

## 3. CLI flags we use

We treat the CLI flags below as supported. (Behavior validated against `--version` output of the installed Claude binary; we degrade if a flag is rejected.)

| Flag | Usage |
|---|---|
| `--verbose` | Mac developer mode. |
| `--append-system-prompt @<file>` | Inject project-specific guidance (e.g., `dnp-remote-system-prompt.md`). |
| `--allowed-tools <csv>` | Restrict tool surface in cautious workspaces. |
| `--permission-mode <mode>` | We surface but never default to bypass. |
| `--mcp-config <file>` | Hand off MCP config without our involvement. |
| `--continue` / `--resume <id>` | Used by Mac when reattaching to a session. |
| `--print` | Non-interactive batch path (optional, not default). |

We **never** ship `--dangerously-skip-permissions` in any default launch command. There is a hidden Mac toggle for it; flipping it raises a warning banner and a session-level audit entry.

## 4. Permission model — how iOS approvals map

When a user clicks "Approve" or "Reject" on iOS, the Mac:

1. Validates the signed `ApprovalResponse` envelope.
2. Looks up the original `ApprovalRequest` in `ApprovalCoordinator`.
3. If approved: replies to Claude's pending hook with `permissionDecision: "allow"` plus, when relevant, an `updatedInput` (e.g., narrowing a Bash command).
4. If rejected: replies with `permissionDecision: "deny"` and a human reason citing the iOS device.
5. Records both transitions in the session's audit log + JSONL transcript.

Approval lifecycle: `created → sentToIOS → viewed → approved/rejected → appliedToRuntime` (or `expired` / `failed`).

## 5. MCP tools — how we surface them

We do not run MCP servers ourselves. We just **observe** and render their tool calls cleanly:

- `tool_name` of the form `mcp__<server>__<tool>` is detected and routed to a `ToolActivityCard` with `provider = .mcp`.
- The relay forwards the tool call's `input`/`output` digests to iOS for inspection (raw values stay on the Mac unless the user opts into developer mode).
- Failed MCP calls become `.toolActivity` with status `.failed` plus a `.warning` event.

## 6. Subagents

Claude Code subagents (under `.claude/agents/`) emit `SubagentStart` and `SubagentStop` hooks. We render these as compact divider cards on iOS so the user sees "🤖 `repo-bootstrap-agent` started → completed in 2m 14s" without needing to read its transcript.

## 7. Memory files

Claude Code automatically loads `CLAUDE.md` and `.claude/rules/*.md`. The `InstructionsLoaded` hook tells us *which* memory files were picked up and *why* (`session_start`, `nested_traversal`, `path_glob_match`, `include`, `compact`). DNP Remote Suite layers its **own** long-term project notebook on top, at `memory/MEMORY.md` with detailed notes in `memory/notes/*.md`. The Mac app maintains those files via `ProjectMemoryService`; they are *not* auto-loaded by Claude Code unless the user `@`-includes them.

## 8. Compatibility matrix (graceful fallback)

| Capability | Required | Fallback if missing |
|---|---|---|
| `claude` on PATH | yes | Mac shows a banner with install instructions; pairing/iOS still work for shell sessions. |
| Hooks ≥ docs §1 set | desirable | Each missing event silently no-ops. EventNormalizer's heuristic command/code-edit detection still works from PTY bytes. |
| `PostToolUseFailure` | nice-to-have | We synthesize a `.warning` from `PostToolUse` + non-zero `tool_response.exit_code` if present. |
| `PreCompact` / `PostCompact` | nice-to-have | We infer compaction from a sudden drop in transcript size. |
| `--allowed-tools` | nice-to-have | Without it, we still classify risk per command and surface approvals. |

## 9. Limitations & risks

- **Estimated context budget.** Claude Code does not reliably expose token counts to hooks today. Our `ContextSnapshot` is `confidence: .estimated` unless future Claude versions expose `context_used` or similar. We always label estimated values as such on iOS.
- **Hook ordering.** Multiple matchers can fire for the same event. Our relay tags every payload with a monotonic local sequence number so the normalizer can stabilize ordering even if Claude's internal scheduler reorders them.
- **Partial PostToolUse data.** Some tools emit a sparse `tool_response`. We never claim what we don't have — the iOS card simply omits fields rather than fabricating placeholders.
- **MCP elicitation.** `Elicitation` is treated as an approval; our default timeout (5 min) can be tuned if a server uses long human-in-the-loop loops.

## 10. Hard rules (do / don't)

✅ Use Claude Code's **public** CLI, settings, hooks, permissions, MCP config.
✅ Treat every iOS approval as a real Claude permission decision.
✅ Fail open in the hook relay; never brick a Claude session because of a transport problem.
✅ Sign every bridge envelope; reject replays and unknown devices.
✅ Persist transcripts and JSONL events under `memory/sessions/{id}/`.

❌ Reverse-engineer Claude's private remote-control protocol.
❌ Use `--dangerously-skip-permissions` as a default.
❌ Show raw PTY bytes on iOS.
❌ Fabricate context numbers.
❌ Trust unsigned or stale-timestamped envelopes.
