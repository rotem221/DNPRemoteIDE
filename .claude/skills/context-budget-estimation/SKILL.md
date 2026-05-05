---
name: context-budget-estimation
description: Use when adjusting how DNP estimates remaining context, when wiring real Claude metadata if/when it ships, or when changing the "session ending soon" warning rules. Triggers on changes to DNPShared/Utilities/ContextEstimator.swift or apps/DNPRemoteMac/DNPRemoteMac/Sessions/ContextMonitorService.swift.
---

## When to use

Anything that touches `ContextSnapshot`, the heuristic estimator, or the warnings UI on iOS.

## Hard rules

- `ContextSnapshot` is the only currency exposed to UI. UI must use `health` + `confidence`, never raw token counts.
- Default heuristic: `ContextEstimator(bytesPerToken: 3.8, totalTokenBudget: 200_000)`. Tune only with evidence.
- Health bands: `healthy ≥ 50% > moderate ≥ 25% > low ≥ 10% > critical`. Encoded in `ContextHealth.health(forPercent:)`.
- Warnings: emit `.lowContext` once on the boundary, `.sessionEndingSoon` once at critical, `.compactionRecommended` when `eventCount > 800` && `health == .moderate`. Suppress duplicates.
- Confidence is sticky to source: official Claude metadata = `.measured`; our heuristic = `.estimated`.
- A `compactCompleted` event reduces estimated usage by ~60% in our model. Don't reset to zero.

## How to apply

### Snapshot from heuristic

```swift
let snap = ContextEstimator().snapshot(
    sessionId: sid,
    transcriptBytes: bytes,
    eventCount: events,
    compactionCount: compactions,
    confidence: .estimated,
    source: .heuristic
)
```

### From official metadata (when available)

```swift
let snap = ContextEstimator(totalTokenBudget: claudeReportedTotal)
    .snapshot(sessionId: sid,
              transcriptBytes: 0,                    // don't add bytes; we trust Claude
              eventCount: 0,
              compactionCount: 0,
              confidence: .measured,
              source: .claudeMetadata)
```

### Suppress duplicate snapshots

```swift
if let prev = lastSnapshot[sid], prev.health == snap.health, prev.warning == snap.warning {
    return nil   // no-op; only emit on actual change
}
```

### iOS UI

- `GlassContextRing(percent:health:)` for the header.
- `ContextStatusHeaderView` shows confidence pill (`MEASURED` / `ESTIMATED`) next to the project name.
- A `GlassCard(tone: .warning)` banner appears below the header when `snap.warning != nil`.

## Examples

**Good** — clear confidence label:

```swift
Text(snap.confidence == .measured ? "MEASURED" : "ESTIMATED")
    .font(.caption2.bold())
    .padding(.horizontal, 6).padding(.vertical, 2)
    .background(LG.surfaceLow, in: Capsule())
```

**Bad** — pretending an estimate is measured:

```swift
contextSnapshot.confidence = .measured   // ❌ never lie about what we know
```

## Pitfalls

- `bytesPerToken` is English-text-y. Code-heavy sessions are chunkier; you may end up over-estimating remaining budget by ~20%.
- Forgetting that hooks may not deliver during compaction — your `transcriptBytes` can drop without you noticing. `PostCompact` is the signal that fixes the model.
- Spamming warnings — always check the suppression rule before broadcasting.
- Reading `percentRemaining` from a UI that didn't bind to the latest snapshot — make sure `ContextSnapshot` lives on `MacAppViewModel.contextSnapshots[sessionId]`.
