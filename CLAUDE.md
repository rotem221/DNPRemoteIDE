# CLAUDE.md — DNP Remote IDE

> Operating instructions for Claude Code agents working in this repository.

## Mission

Build **DNP Remote IDE** — a native macOS IDE that hosts Claude Code in
a real PTY, surfaces every command, file edit, tool call and approval
as a clean stream of semantic events, and lets you supervise a session
from a paired iPhone over a signed local WebSocket bridge.

This repository contains:

1. **DNP Remote Mac** (`apps/DNPRemoteMac/`) — the macOS host app.
   Owns execution: PTY, Claude Code launch, filesystem, hooks,
   permissions, bridge server, IDE shell.
2. **DNPShared** (`Packages/DNPShared/`) — Swift package with the
   models, protocol, events, security primitives, and persistence
   contracts the Mac app uses.
3. **Tools** (`tools/`) — Swift CLIs invoked by the Mac app for hook
   relays, offline event normalization, and session export.

> The companion **iPhone client** that pairs with this Mac app over
> the local bridge is distributed separately via the App Store and is
> not part of this repository.

## Important product rules

- UI language is **English** throughout the Mac app.
- Use only **supported** Claude Code surfaces: CLI, settings,
  permissions, hooks, MCP configuration, local files, memory files.
  Do not reverse-engineer private APIs.
- Respect Claude Code permissions. Do **not** default to dangerous
  bypass modes (no `--dangerously-skip-permissions`).
- Use a **real PTY** for Claude Code I/O (not a `Process` pipe).
- Use hooks via `.claude/settings.json` for structured event capture.
- Persist every session locally (transcripts, JSONL events,
  summaries, metadata) under `memory/sessions/`.
- The local bridge to a paired iPhone is **always Ed25519-signed**
  with QR-bootstrapped device keys held in the system Keychain.
  Sign every bridge envelope; reject replays and unknown devices.
- Display context remaining and "session ending soon" warnings.
- Capture crashes locally to `memory/crashes/`.
- Maintain a long-term project notebook at `memory/MEMORY.md` (index)
  plus `memory/notes/*.md`.

## UI direction

Professional modern dark IDE — split panes, refined toolbars, terminal
pane center, event feed right, sidebar left. Inspired by Cursor and
modern AI developer tools. Not playful, not mobile-like.

## Repository layout

See `docs/ARCHITECTURE.md`. Top-level:

```
DNPRemoteIDE/
├── apps/DNPRemoteMac/        # macOS Xcode project (XcodeGen)
├── Packages/DNPShared/       # Swift Package
├── tools/dnp-hook-relay/     # Swift CLI for Claude Code hooks
├── docs/                     # Architecture, security, protocol, etc.
├── .claude/                  # Subagents, skills, hook settings
├── memory/                   # sessions/, notes/, crashes/, MEMORY.md
├── scripts/                  # bootstrap, doctor, release, Sparkle
└── .github/workflows/        # CI pipelines (release, etc.)
```

## Quality bar

- Buildable, modular, clean, testable, documented.
- Local-first; no private APIs; no shortcuts.
- Permissions respected; approvals auditable.
