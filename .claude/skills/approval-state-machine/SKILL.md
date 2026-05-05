---
name: approval-state-machine
description: Use when changing the ApprovalCoordinator actor on Mac — states, transitions, signed responses, timeouts, audit log. Triggers on changes to apps/DNPRemoteMac/DNPRemoteMac/Sessions/ApprovalCoordinator.swift or to approval payload types in DNPShared.
---

## When to use

Anywhere the lifecycle of an approval moves: created, sent, viewed, approved/rejected, applied, expired, failed.

## Hard rules

- The state machine is `created → sentToIOS → viewed → approved | rejected → appliedToRuntime` with `expired` and `failed` branches.
- Mutations only via `ApprovalCoordinator` API (`create`, `markSentToIOS`, `markViewed`, `apply`, `markAppliedToRuntime`, `markFailed`).
- Every transition appends an audit entry **and** emits a `SessionEvent` of type `.approvalResult` (or `.approvalRequired` on creation) into `events.jsonl`.
- The first valid `ApprovalResponse` wins; later responses get `BridgeErrorCode.approvalAlreadyDecided`.
- Stale (`Date() > timeoutAt`) responses are auto-expired before applying.
- Only signed envelopes from trusted devices reach `apply`. Unauthenticated input never makes it past the bridge layer.

## How to apply

### State transitions

```swift
actor ApprovalCoordinator {
    func create(_ req: ApprovalRequest) {
        pending[req.id] = req
        record(req.id, .requested, nil, "created")
    }
    func markSentToIOS(_ id: UUID) { update(id) { $0.status = .sentToIOS }; record(id, .sentToIOS, nil, nil) }
    func markViewed(_ id: UUID, by deviceId: UUID) { update(id) { $0.status = .viewed }; record(id, .viewed, deviceId, nil) }

    func apply(_ response: ApprovalResponse) -> ApplyResult {
        guard var existing = pending[response.approvalId] else { return .notFound }
        if existing.status == .approved || existing.status == .rejected { return .alreadyDecided(existing.status) }
        if Date() > existing.timeoutAt { ... return .expired }
        existing.status = response.decision == .approve ? .approved : .rejected
        existing.decidedAt = response.decidedAt
        existing.decidedByDeviceId = response.deviceId
        pending[existing.id] = existing
        record(...)
        return .accepted(existing)
    }
}
```

### Audit log entry

```swift
struct ApprovalAuditEntry: Codable, Sendable {
    let approvalId: UUID
    let lifecycle: ApprovalLifecycle
    let timestamp: Date
    let actorDeviceId: UUID?
    let note: String?
}
```

### Timeout handling

```swift
Task {
    try? await Task.sleep(nanoseconds: UInt64(req.timeoutAt.timeIntervalSinceNow * 1e9))
    if let still = await coordinator.snapshot().first(where: { $0.id == req.id }),
       still.status == .created || still.status == .sentToIOS || still.status == .viewed {
        await coordinator.markFailed(req.id, reason: "expired")
    }
}
```

### Apply to runtime

After `.accepted(req)` in apply:

```swift
emitDecisionToClaude(req)        // permissionDecision JSON to the still-blocked hook
await coordinator.markAppliedToRuntime(req.id)
```

## Examples

**Good** — atomic transition, audit trail intact:

```swift
let result = await coordinator.apply(response)
switch result {
case .accepted(let req): /* relay decision */
case .alreadyDecided(let status): bridge.send(.error, code: .approvalAlreadyDecided, ...)
case .expired:                    bridge.send(.error, code: .approvalExpired, ...)
case .notFound:                   bridge.send(.error, code: .approvalNotFound, ...)
}
```

**Bad** — flipping state directly:

```swift
pending[id]?.status = .approved   // ❌ bypasses audit log + checks
```

## Pitfalls

- Forgetting that `viewed` is observable to the user — emit it on the first `liveEvent` delivery, not on response.
- Letting `markSentToIOS` happen multiple times when iOS reconnects — guard against.
- Treating `markFailed` as terminal but forgetting to emit a `.approvalResult` so the iOS card disappears.
- Storing approvals only in memory. They must survive a Mac relaunch (in-memory store is fine for now; persistence is on the roadmap).
