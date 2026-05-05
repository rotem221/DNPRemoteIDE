# Roadmap — DNP Remote Suite

## Current scaffold (this commit)

The repo ships a complete *scaffold*, not a final product. Everything below is in the tree:

- ✅ Repo layout, `CLAUDE.md`, `.claude/settings.json`, gitignore, scripts.
- ✅ `DNPShared` package with full models, payloads, protocol envelopes, signing, replay protection, ANSI cleaner, risk classifier, context estimator, persistence contracts, Markdown transcript renderer, unit tests.
- ✅ Mac app shell (SwiftUI, dark IDE), services scaffolded: `PTYRuntimeService` (real `forkpty`), `ClaudeSessionService`, `EventNormalizerService`, `ApprovalCoordinator` (actor), `ContextMonitorService`, `BridgeServerService` (length-prefixed JSON over Network.framework), `DeviceTrustService` (Keychain + trusted-device store), `SessionPersistenceService` (in-memory stores + on-disk JSONL/Markdown), `ProjectMemoryService`, `CrashReporter` (signal + uncaught-exception handlers).
- ✅ iOS app shell (SwiftUI, dark Liquid Glass), services scaffolded: `IOSAppViewModel`, `BridgeClientService`, `IOSPairingService`, `IOSKeyService`, `LocalMemoryService`. Full Liquid Glass component library and every feed-card type.
- ✅ `tools/dnp-hook-relay` Swift CLI (fail-open with JSONL fallback).
- ✅ Docs: PRD, Architecture, Security, Protocol, UX guidelines, Test plan, Claude Code integration.
- ✅ `.claude/agents/` and `.claude/skills/` (16 + 15 files) describing how a Claude Code session should help maintain this repo.

## Phase 1 — first run-able demo (next milestone)

| Item | Why | Where |
|---|---|---|
| Wire `MacAppViewModel` end-to-end | Currently each service is constructed but the data pipeline is partly stubbed. | `MacAppViewModel.bootstrap()` |
| Hook relay HTTP endpoint on Mac | Today the Mac doesn't yet accept POSTs from the relay; the relay falls back to JSONL, which the Mac doesn't yet ingest. | `BridgeServerService` + a small `NWListener` for `127.0.0.1:18733/hook`. |
| QR scanner camera path on iOS | Manual entry works; the AVFoundation path is a stub. | `Pairing/QRScannerView` |
| End-to-end signed envelopes between Mac and iOS | Pieces are present; the signed handshake on the bridge isn't wired yet. | `BridgeServerService.onIncomingFrame` + `BridgeClientService` |
| Persist `Session` records to disk on every change | In-memory stores survive a single launch; no autoload yet. | `SessionPersistenceService` (replace `InMemorySessionStore` with SQLite/Core Data). |
| Real PTY → normalizer → feed pipeline | `EventNormalizerService` exists; it isn't yet subscribed to the PTY stream from `MacAppViewModel`. | Glue code in `MacAppViewModel`. |

Acceptance: launching Mac, pairing iPhone via QR, running `ls -la` on Mac, seeing one `CommandEventCard` on iPhone.

## Phase 2 — quality

| Item | Why |
|---|---|
| Replace in-memory stores with SQLite (or Core Data) | Durability across launches. |
| Bonjour discovery + auto-connect | Manual endpoint entry is friction. |
| TLS-on-LAN | Defense in depth (signing already covers integrity, but encryption hides content). |
| Biometric gate before iOS approval is sent | Defense against stolen devices. |
| "Review-only" pairing mode | A device that can see but not approve. |
| Theming for Reduce Transparency | Liquid Glass falls back to opaque cards when system reduces transparency. |

## Phase 3 — depth

| Item | Why |
|---|---|
| Voice prompts on iOS | Single-tap dictation for hands-busy users. |
| Apple Watch glance | Pending-approvals badge + "approve from wrist" with biometric gate. |
| Multi-Mac fan-out | One iPhone, multiple Macs; bridges discovered via Bonjour. |
| Exportable session bundles | `dnp-session-exporter` real implementation. |
| Telemetry for the parser | Self-report % of events that fall into `UnknownCard` so we can grow detectors. |
| Subagent dashboards | Per-subagent timeline pulled from `SubagentStart`/`SubagentStop`. |

## Phase 4 — long term

| Item | Why |
|---|---|
| Cross-WAN through end-to-end-encrypted relay | Optional, opt-in, defaults off. |
| Plugin slots in the Mac IDE pane | Embedded code editor, file diff viewer, git inspector. |
| Multi-user single Mac | Per-OS-user identity isolation. |
| Public schema for `SessionEvent` | So third-party tools can consume the JSONL stream. |

## Stop-doing list

These were tempting but explicitly **out of scope** for the suite:

- Reverse-engineering Claude Code's private remote-control protocol.
- Building our own Claude wrapper that proxies tool calls. We use the public CLI + hooks.
- An iOS terminal emulator. The phone shows semantic events; raw bytes belong on the Mac.
- Defaults that bypass permissions.

## Calendar (suggested)

| Week | Focus |
|---|---|
| 1 | Phase 1 plumbing — bring up first end-to-end demo. |
| 2 | Phase 1 polish + UI tests. |
| 3 | Phase 2 (durability + security hardening). |
| 4 | Phase 2 polish + first external review. |
| 5–6 | Phase 3 high-leverage items (Bonjour, Watch glance). |
| 7+ | Phase 4 selectively as needs surface. |
