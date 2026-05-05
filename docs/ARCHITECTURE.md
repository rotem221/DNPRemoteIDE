# Architecture — DNP Remote Suite

## Layers

```
┌─────────────────────────────────────────────────────────────────────────┐
│  DNP Remote Mac (macOS app)                                             │
│  ┌─ UI (SwiftUI dark IDE) ─────────────────────────────────────────┐   │
│  │  MacAppShellView · Workspace · Pairing · Settings · Diagnostics │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                       ▲                                                 │
│                       │ MainActor                                       │
│  ┌─ Services (actors) ────────────────────────────────────────────┐   │
│  │  PTYRuntime · ClaudeSession · EventNormalizer · HookRelaySink  │   │
│  │  ApprovalCoordinator · ContextMonitor · SessionPersistence     │   │
│  │  BridgeServer · DeviceTrust · ProjectMemory · CrashReporter    │   │
│  └────────────────────────────────────────────────────────────────┘   │
│         │              │            │              │                    │
│  ┌──────┴──────┐ ┌─────┴─────┐ ┌───┴────┐ ┌──────┴───────┐            │
│  │   PTY child │ │ Hook relay │ │ Local  │ │ Bonjour/TCP │            │
│  │  (claude)   │ │ (stdin JSON)│ │ disk  │ │ to iOS       │            │
│  └─────────────┘ └────────────┘ └────────┘ └──────────────┘            │
└─────────────────────────────────────────────────────────────────────────┘
                                  │  signed BridgeEnvelope<P>
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  DNP Remote iOS (iOS app)                                               │
│  ┌─ UI (SwiftUI Liquid Glass) ──────────────────────────────────────┐   │
│  │  IOSAppShell · ContextStatusHeader · Feed · Composer ·          │   │
│  │  Approval Carousel · Sessions Sidebar · Settings · Diagnostics  │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                       ▲                                                 │
│  ┌─ Services ────────────────────────────────────────────────────┐    │
│  │  IOSAppViewModel · BridgeClient · IOSPairing · IOSKeyService  │    │
│  │  LocalMemoryService                                           │    │
│  └───────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘

Both sides import:
┌─────────────────────────────────────────────────────────────────────────┐
│  DNPShared (SwiftPM, macOS 14 / iOS 17)                                 │
│  Models · Events · Payloads · Context · Protocol · Security · Coders   │
└─────────────────────────────────────────────────────────────────────────┘
```

## Data flow — terminal byte → iOS card

```
                  ┌───────────────────────────────────────────────────┐
PTY stdout/err ──▶│ ANSICleaner                                       │
                  │ - strips CSI/OSC/control bytes                   │
                  │ - collapses \r overwrites                        │
                  └───┬──────────────────────────────────────────────┘
                      ▼
                  ┌──────────────────────────────────────────────────┐
                  │ NoiseFilter                                      │
                  │ - drops empty redraws, prompt echoes            │
                  │ - dedups repeated lines within window           │
                  └───┬──────────────────────────────────────────────┘
                      ▼
                  ┌──────────────────────────────────────────────────┐
                  │ EventDetector                                    │
                  │ - command start ($/>) + classify risk            │
                  │ - command end (exit code if visible)             │
                  │ - "wrote X.swift" → CodeEditPayload              │
                  └───┬──────────────────────────────────────────────┘
                      ▼
hook JSON ─────────▶┌──────────────────────────────────────────────┐
                    │ HookRelaySink                                │
                    │ - PostToolUse → CodeEdit / FileChanged       │
                    │ - PermissionRequest → ApprovalRequired       │
                    │ - PreCompact / PostCompact / SessionEnd ...  │
                    └───┬──────────────────────────────────────────┘
                        ▼
                    ┌──────────────────────────────────────────────┐
                    │ EventNormalizer                              │
                    │ - assigns monotonic sequence per session     │
                    │ - merges/orders streams                      │
                    │ - severity tagging                           │
                    └───┬──────────────────────────────────────────┘
                        ▼
                    ┌────────────────────────────────────────────┐
                    │ SessionPersistence (JSONL + Markdown)      │
                    │ ContextMonitor (snapshot + warnings)       │
                    └───┬────────────────────────────────────────┘
                        ▼
                    ┌────────────────────────────────────────────┐
                    │ BridgeServer  ── signed envelope ──▶ iOS  │
                    └────────────────────────────────────────────┘
```

## Threading

- **Mac:** `MacAppViewModel` is `@MainActor`. All I/O lives in actor types (`ApprovalCoordinator`, `ContextMonitorService`, `SessionPersistenceService`, `DeviceTrustService`, `ProjectMemoryService`). PTY reads run on a dedicated `DispatchSourceRead` and post bytes to the normalizer via an `AsyncStream`.
- **iOS:** `IOSAppViewModel` is `@MainActor`. Bridge I/O runs on a private `DispatchQueue("dnp.bridge.client")`. Incoming frames are decoded on that queue, then dispatched to the main actor for UI updates.

## Lifecycle

1. **App launch.** `MacAppViewModel.bootstrap()` installs crash handlers, restores sessions from `SessionPersistenceService`, starts `BridgeServer`, loads trusted devices.
2. **New session.** User picks a project folder; `ClaudeSessionService.launchCommand` builds args; `PTYRuntimeService.spawn` starts the child; output stream feeds `EventNormalizerService`; events propagate to UI + iOS.
3. **Approval.** Claude triggers `PermissionRequest` hook → relay → normalizer emits `.approvalRequired` → `ApprovalCoordinator.create(...)`. Mac signs an envelope and broadcasts. iOS shows `ApprovalCard`. User decides; iOS signs response; Mac verifies, calls `apply(...)`. The hook (still blocking on stdin) receives a `permissionDecision` JSON.
4. **Crash.** PTY child exits unexpectedly → `CrashReporter.recordRecoverable(.ptyExitedUnexpectedly, ...)` → file written under `memory/crashes/` + `.crash` event into the feed.
5. **Bridge drop.** iOS reconnects with exponential backoff; `subscribeSession` carries `lastSequenceSeen` so the Mac backfills only what was missed.

## Module boundaries

| Concern | Owner |
|---|---|
| Models / payloads / event taxonomy | `DNPShared` |
| Bridge envelope + signing + replay | `DNPShared` |
| ANSI cleaning + risk classification + context estimation | `DNPShared` (so tools can reuse) |
| PTY runtime, Claude launch, hook relay sink | Mac app only |
| Liquid Glass UI primitives | iOS app only |
| Persistence (Mac side) | Mac app (in-memory now; SQLite/Core Data planned) |
| Persistence (iOS side, cache only) | iOS app `LocalMemoryService` |

## Failure handling

- Hook relay is **fail-open**. A failed POST to Mac falls back to `.dnp/events/hooks.jsonl`.
- Bridge server validates protocol version, signature, nonce, timestamp. Failures emit a `bridgeError` envelope back, never panic.
- Approval Coordinator rejects stale or already-decided responses with structured errors.
- Crash reporter installs handlers idempotently.

## Recovery on relaunch

`SessionPersistenceService.bootstrap()` reads:
1. `memory/sessions/*/metadata.json` → restores `Session` list.
2. For the selected session, the last N JSONL events are streamed back into `feed[sessionId]` so the UI is hot.
3. Sessions with status `.running` whose PTY process is no longer alive get downgraded to `.crashed` and a `.crash` feed event is appended.
