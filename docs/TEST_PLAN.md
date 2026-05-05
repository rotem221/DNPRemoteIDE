# Test Plan — DNP Remote Suite

## Pyramid

```
          ┌────────────────────────┐
          │   UI smoke (light)     │   1–2 happy-path runs per app
          ├────────────────────────┤
          │   Integration tests    │   PTY+Claude, hook relay round-trip,
          │                        │   bridge round-trip, recovery
          ├────────────────────────┤
          │   Unit tests (heavy)   │   shared models, parser, signing,
          │                        │   risk classifier, context estimator
          └────────────────────────┘
```

## DNPShared unit tests

Located under `Packages/DNPShared/Tests/DNPSharedTests`. Run with `swift test` (or `./scripts/test-all.sh`).

| File | What it covers |
|---|---|
| `CodableRoundTripTests` | `Session`, `SessionEvent` w/ each payload kind, `ApprovalRequest` for every `ApprovalStatus`, `ContextSnapshot`. |
| `SigningTests` | `BridgeSigner.sign + verify`, tampered payload rejection, `ReplayProtection` rejects repeated nonces and stale timestamps. |
| `ANSIAndRiskTests` | `ANSICleaner.clean` strips CSI/OSC, `collapseCarriageReturns` keeps the last rendering, `RiskClassifier` levels (low/medium/high/critical) for representative commands and file-write paths, `ContextEstimator` warns at low percentages. |

Add as protocol grows:
- Bridge envelope canonicalization stability across rebuilds (golden bytes).
- `MarkdownTranscript.render` stable output across event types.
- Decoding of an unknown future `Kind` in `SessionEventPayload` falls back gracefully (when we add `case unknown`).

## Mac integration tests

Run via `xcodebuild test -scheme DNPRemoteMac` once the test target is added.

| Suite | Plan |
|---|---|
| `PTYRuntimeTests` | spawn `/bin/echo hello`, assert stream yields `"hello\r\n"`, exit reaper fires within 1 s. |
| `EventNormalizerTests` | feed canned PTY transcripts (saved under `Tests/Fixtures/`), assert exact ordered list of `SessionEvent`s. |
| `HookRelaySinkTests` | feed each known hook event JSON shape (per `docs/CLAUDE_CODE_INTEGRATION.md`), assert mapping. |
| `ApprovalCoordinatorTests` | full lifecycle: create → sentToIOS → viewed → approved → appliedToRuntime; replay rejection; expired branch. |
| `BridgeServerTests` | round-trip `hello` ↔ `helloAck`; `subscribeSession` triggers a backfill batch with sequence ≥ requested; tampered envelope rejected. |
| `ContextMonitorTests` | feed event sequence, assert health transitions and warning emission. |
| `SessionPersistenceTests` | append events → restart service → restore identical event list and Markdown. |
| `ProjectMemoryTests` | append note → `MEMORY.md` index updated; rebuild idempotent. |
| `CrashReporterTests` | `recordRecoverable` writes a JSON file with the right schema. |

## iOS integration tests

| Suite | Plan |
|---|---|
| `BridgeClientTests` | connect → send `userPrompt` → assert envelope is signed with iOS key; reject if Mac envelope signature fails verify. |
| `IOSPairingTests` | scan token → store `PairedMacInfo`; unpair clears it. |
| `LocalMemoryTests` | save/restore each cache file. |
| `IOSKeyServiceTests` | first launch generates a key + device id; second launch reuses them. |

## UI smoke tests

We ship two snapshot/scenario tests per app, no more (UI tests are slow and brittle):

- **Mac UI smoke**: launch app → workspace renders → toolbar shows "Bridge online" within 2 s.
- **iOS UI smoke**: launch with mocked `IOSPairingService.loadPairedMac()` → SessionDetail visible → tapping send button calls `IOSAppViewModel.sendPrompt` once.

## Test data

Fixtures (saved as plain files in `Tests/Fixtures/`):

| File | Content |
|---|---|
| `pty-npm-install.txt` | Realistic PTY capture of `npm install`. |
| `pty-rm-rf-rejected.txt` | A risky command echo that should classify `.high` and trigger a `.warning`. |
| `hooks/UserPromptSubmit.json` | Sample stdin JSON from the docs. |
| `hooks/PreToolUse.bash.json` | Bash variant. |
| `hooks/PermissionRequest.json` | With `permission_suggestions`. |
| `hooks/PostCompact.json` | Compaction completed. |

## CI

GitHub Actions workflow `ci.yml` (planned):

```yaml
jobs:
  shared:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - run: swift test --package-path Packages/DNPShared
  bootstrap:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - run: brew install xcodegen
      - run: ./scripts/bootstrap.sh
      - run: ./scripts/doctor.sh
```

## Definition of done

A change is "tested" when:
1. It has at least one positive case test (the happy path).
2. It has at least one negative case test where applicable (replay, malformed, timeout).
3. New `SessionEventType` values come with a `MarkdownTranscript.render` golden.
4. New protocol fields/messages have a sample-frame entry in `docs/PROTOCOL.md`.
