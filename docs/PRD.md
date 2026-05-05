# DNP Remote Suite — Product Requirements

## 1. What we're building

DNP Remote Suite is a local-first system that lets a user run **Claude Code** on a Mac and supervise it from an **iPhone**. The Mac is the host; the iPhone is the remote control. Two completely separate apps, plus a shared Swift package.

| App | Platform | Role |
|---|---|---|
| **DNP Remote Mac** | macOS 14+ | PTY runtime, Claude Code launcher, hooks/permissions, bridge server, IDE-style UI. |
| **DNP Remote iOS** | iOS 17+ | Liquid Glass remote: sessions, semantic feed, approvals, composer, context monitor. |
| **DNPShared** | SwiftPM | Models, protocol envelopes, events, security primitives, persistence contracts. |

## 2. Hard product rules

1. UI language is English on both apps.
2. Mac and iOS are **separate Xcode projects** under `apps/`.
3. Shared types live only in `Packages/DNPShared`. No duplication.
4. Claude Code runs **only on the Mac**, inside a **real PTY**. iOS never spawns shell or Claude.
5. iOS shows **clean semantic events** only — no raw terminal clutter.
6. We use only documented Claude Code surfaces: CLI, settings, hooks, permissions, MCP config, memory files.
7. `--dangerously-skip-permissions` is **never** a default. iOS approvals never grant it.
8. Pairing is one-time, QR-bootstrapped, with Ed25519 device keys in Keychain.
9. Every bridge envelope is signed, nonce-bound, and replay-checked.
10. Sessions persist as `transcript.md` + `events.jsonl` + `summary.md` + `metadata.json` under `memory/sessions/{id}/`.
11. Crashes log to `memory/crashes/`; warnings flow as feed events.
12. Every project gets a long-term notebook at `<project>/memory/MEMORY.md` indexing `notes/*.md`.

## 3. Mac app — overview

Professional dark IDE shell, three-pane workspace:

```
┌─ Toolbar (session · status · context · bridge ──────────────────────────┐
├──────────────┬───────────────────────────┬──────────────────────────────┤
│ Sidebar      │ Terminal (PTY)            │ Event Feed                   │
│ Sessions     │ Claude Code running here  │ Same semantic events iOS sees│
│ Pairing      │ Composer                  │ + developer detail mode      │
│ Settings     │                           │                              │
│ Diagnostics  │                           │                              │
└──────────────┴───────────────────────────┴──────────────────────────────┘
```

Required screens: Workspace, Pairing Center (QR, trusted devices), Settings (Claude / Bridge / Context / Feed), Diagnostics (claude path + version, PTY availability, bridge port, issues).

Required services (per `apps/DNPRemoteMac/DNPRemoteMac/`):

- `PTYRuntimeService` — `forkpty`-based real PTY runtime. Stdin/stdout/stderr, resize, lifecycle.
- `ClaudeSessionService` — detects path/version, builds launch flags.
- `EventNormalizerService` — ANSI cleaner → noise filter → command/code-edit/tool detector → `SessionEvent`.
- `ApprovalCoordinator` — actor holding pending approvals + audit log.
- `ContextMonitorService` — heuristic `ContextSnapshot`s with `.estimated`/`.measured` confidence.
- `BridgeServerService` — local 4-byte-length-prefixed JSON over TCP (Network.framework). One frame = one signed envelope.
- `DeviceTrustService` — Ed25519 identity in Keychain, pairing tokens, trusted device store.
- `SessionPersistenceService` — JSONL events + transcript.md + summary.md + metadata.json.
- `ProjectMemoryService` — `memory/MEMORY.md` index + `notes/*.md` body files; auto-rebuilds index on each note.
- `CrashReporter` — signal handlers + uncaught Swift exception handler → `memory/crashes/<ts>.json`.

## 4. iOS app — overview

Dark-first **Liquid Glass** companion. The `LG` namespace defines the palette and primitives (`GlassCard`, `GlassPrimaryButtonStyle`, `GlassSecondaryButtonStyle`, `GlassStatusPill`, `GlassContextRing`).

Required screens:

- Pairing screen (QR scan or manual entry) — visible until paired.
- Session detail (default screen post-pair):
  - **ContextStatusHeader** — context ring + session title + project name + connection pill + warning banner.
  - **Feed** — scrollable timeline of `SessionEvent`s. Each `SessionEventType` maps to a specific card.
  - **Composer** — multi-line prompt input with attachment + send buttons.
- Approval Carousel — appears as a sheet when there are pending approvals.
- Sidebar (`SessionSidebarView`) — sessions grouped by Active / Pending / Low context / Disconnected / Completed.
- Settings — connection, pairing, feed prefs, about.
- Diagnostics — connection state, last error, warnings, cached crashes.

Required event cards (one component per `SessionEventType`):

- `UserMessageBubble`, `AssistantMessageBubble`
- `ThinkingSummaryCard` (safe summary only — no hidden chain-of-thought)
- `CommandEventCard` with risk-tinted glass background
- `CodeEditCard` (path + ±line counts + diff preview)
- `FileChangedCard`, `ToolActivityCard`
- `ApprovalEventCard` (history) + `ApprovalCard` (active)
- `WarningCard`, `ErrorCard`
- `StatusCard` (compaction, session end, subagent lifecycle)
- `UnknownCard` — compact fallback when an event type isn't yet recognized.

## 5. Event taxonomy

Every signal is normalized into a `SessionEvent` with `type: SessionEventType` and a `payload: SessionEventPayload?` of the matching kind:

```
.userMessage / .assistantMessage / .thinkingSummary
.commandStarted / .commandOutput / .commandCompleted
.codeEditSummary / .fileChanged / .toolActivity
.approvalRequired / .approvalResult
.warning / .error / .crash
.contextUpdate / .sessionStatusUpdate
.sessionStarted / .sessionEnded
.compactStarted / .compactCompleted
.subagentStarted / .subagentCompleted
.unknown   ← compact fallback
```

Severity is `.debug | .info | .notice | .warning | .error | .critical`. Source is `.mac | .ios | .hookRelay | .parser | .system | .user`.

## 6. Approval flow

States: `created → sentToIOS → viewed → approved | rejected → appliedToRuntime` (with `expired` / `failed` branches). Mac signs the request; iOS signs the response; Mac validates and applies the decision back to Claude via `permissionDecision`. Audit log captures every transition. iOS UI: large `ApprovalCard` with risk-tinted glass, code monospaced target, two glass buttons (`Approve` / `Reject`).

## 7. Context monitoring

`ContextSnapshot { used, total, remaining, percent, health, confidence, source, warning }`. Health bands: `healthy ≥ 50% > moderate ≥ 25% > low ≥ 10% > critical`. Warnings: `lowContext`, `sessionEndingSoon`, `compactionRecommended`, `parserUncertainty`. iOS shows the value in a `GlassContextRing` and a banner when `warning != nil`. Confidence label (`measured` / `estimated`) is always visible.

## 8. Pairing & bridge

QR pairing: Mac issues a single-use 5-minute token + displays QR. iOS scans, sends `pairingRequest` (with its Ed25519 public key); Mac approves locally, stores trusted device, returns `pairingResponse` (with Mac public key + endpoint). Both sides keep keys in Keychain.

Bridge: local TCP, framed `<u32 big-endian length><JSON envelope>`. `BridgeEnvelope<P>` is signed Ed25519 over canonical JSON (`signature` zeroed during signing). Replay protection: nonce LRU per sender (4096 entries) + ±60 s timestamp window.

## 9. Persistence

| Path | Purpose |
|---|---|
| `memory/sessions/{id}/events.jsonl` | Append-only canonical event log. |
| `memory/sessions/{id}/transcript.md` | Human-readable Markdown of the same events. |
| `memory/sessions/{id}/summary.md` | Periodic auto-summary. |
| `memory/sessions/{id}/metadata.json` | Session record (status, project, timestamps). |
| `memory/crashes/<ts>-<uuid>.json` | Crash reports. |
| `memory/MEMORY.md` (project) | One-line index of long-term notes. |
| `memory/notes/*.md` (project) | Note bodies. |

## 10. Acceptance criteria

The project is "good" when (and only when):

- `./scripts/bootstrap.sh` regenerates Mac + iOS Xcode projects without errors.
- `./scripts/test-all.sh` passes on `Packages/DNPShared`.
- `./scripts/doctor.sh` reports green (claude on PATH, projects generated, hook-relay built).
- Mac app launches, detects the Claude binary, can start a PTY shell.
- iOS app pairs with the Mac via QR (or manual endpoint).
- A Bash command run on Mac appears as a single `CommandEventCard` on iOS — no terminal clutter.
- An iOS approval round-trips into a real `permissionDecision` on the Mac.
- A `Session ending soon` warning fires when `ContextEstimator` reports `health == .critical`.
- Every transition is in `events.jsonl`. Restarting the Mac app restores all sessions and feeds.
- A simulated PTY crash creates a file under `memory/crashes/` and a `.crash` feed event.

See [`ROADMAP.md`](./ROADMAP.md) for phasing, [`ARCHITECTURE.md`](./ARCHITECTURE.md) for module wiring.
