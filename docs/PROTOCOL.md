# Bridge Protocol — DNP Remote Suite

> Protocol version: **1**

## Wire format

One TCP connection per iOS client; on a bonjour-published `_dnp-remote._tcp` service. Each frame:

```
┌──────────┬──────────────────────┐
│ u32 BE   │ JSON envelope bytes  │
│ length   │ (UTF-8)              │
└──────────┴──────────────────────┘
```

`length` is the byte count of the JSON. Max 4 MB per frame. The JSON is exactly one `BridgeEnvelope<P>` (see [`SECURITY.md`](./SECURITY.md) for signing rules).

## Envelope

```ts
type BridgeEnvelope<Payload> = {
  id: UUID;                  // unique per message
  type: BridgeMessageType;   // see below
  protocolVersion: number;   // currently 1
  senderId: UUID;
  recipientId: UUID | null;
  sessionId: UUID | null;
  timestamp: string;         // ISO-8601 with ms, UTC
  nonce: string;             // base64, 16 bytes
  signature: string;         // base64 Ed25519 over canonical JSON with signature=""
  payload: Payload;
};
```

## Message types

| Type | Direction | Payload |
|---|---|---|
| `hello` | iOS → Mac (post-connect) and Mac → iOS (helloAck) | `HelloPayload` |
| `helloAck` | Mac → iOS | `HelloPayload` |
| `pairingRequest` | iOS → Mac (during pairing) | `PairingRequest` |
| `pairingResponse` | Mac → iOS | `PairingResponse` |
| `sessionListRequest` | iOS → Mac | `SessionListRequestPayload` |
| `sessionListResponse` | Mac → iOS | `SessionListResponsePayload` |
| `subscribeSession` | iOS → Mac | `SubscribeSessionPayload` |
| `unsubscribeSession` | iOS → Mac | `UnsubscribeSessionPayload` |
| `eventBatch` | Mac → iOS | `EventBatchPayload` |
| `liveEvent` | Mac → iOS | `LiveEventPayload` |
| `userPrompt` | iOS → Mac | `UserPromptPayload` |
| `approvalResponse` | iOS → Mac | `ApprovalResponsePayload` |
| `heartbeat` | bidirectional | `HeartbeatPayload` |
| `reconnect` | Mac → iOS | `ReconnectPayload` |
| `revoke` | Mac → iOS | `RevokePayload` |
| `error` | bidirectional | `BridgeErrorPayload` |

## Sequencing

Per session, the Mac maintains a monotonic `sequence: UInt64`. iOS's `subscribeSession` carries `lastSequenceSeen`; the Mac:

1. Sends `eventBatch{ isBackfill: true, events: [...], highestSequence: N }` with up to `eventBackfillBatchSize` (default 200) events at a time, paginating until caught up.
2. Then transitions to `liveEvent` for new events as they're produced.

iOS may resubscribe at any time; Mac re-uses the latest `lastSequenceSeen` to backfill the gap.

## Heartbeat

Each side sends `heartbeat` every `heartbeatIntervalSeconds` (15 s). If the other side doesn't see one within `heartbeatTimeoutSeconds` (45 s), it triggers a reconnect locally.

## Sample frames

### `hello` (iOS → Mac)

```json
{
  "id": "1A2C5C40-…",
  "type": "hello",
  "protocolVersion": 1,
  "senderId": "9F2D9F21-…",
  "recipientId": null,
  "sessionId": null,
  "timestamp": "2026-04-29T19:11:32.482Z",
  "nonce": "rH3M2…==",
  "signature": "fGz5w8…==",
  "payload": {
    "deviceId": "9F2D9F21-…",
    "deviceName": "Rotem's iPhone",
    "platform": "iPhone",
    "appVersion": "0.1",
    "protocolVersion": 1
  }
}
```

### `subscribeSession` (iOS → Mac)

```json
{
  "type": "subscribeSession",
  "payload": { "sessionId": "…", "lastSequenceSeen": 247 },
  "…": "…"
}
```

### `eventBatch` (Mac → iOS, backfill)

```json
{
  "type": "eventBatch",
  "payload": {
    "sessionId": "…",
    "isBackfill": true,
    "highestSequence": 380,
    "events": [
      {
        "id": "…",
        "sessionId": "…",
        "sequence": 248,
        "timestamp": "2026-04-29T19:08:11.001Z",
        "type": "commandStarted",
        "severity": "info",
        "source": "parser",
        "title": "Running: npm install",
        "summary": null,
        "payload": {
          "kind": "command",
          "value": {
            "command": "npm install",
            "workingDirectory": "/Users/.../app",
            "risk": "medium",
            "status": "running",
            "startedAt": "2026-04-29T19:08:10.998Z"
          }
        }
      }
    ]
  }
}
```

### `approvalResponse` (iOS → Mac)

```json
{
  "type": "approvalResponse",
  "payload": {
    "response": {
      "approvalId": "…",
      "sessionId": "…",
      "decision": "approve",
      "deviceId": "9F2D9F21-…",
      "decidedAt": "2026-04-29T19:09:21.122Z",
      "comment": null
    }
  }
}
```

### `error` (Mac → iOS)

```json
{
  "type": "error",
  "payload": {
    "code": "approvalAlreadyDecided",
    "message": "Approval 9D… is already in state 'approved'",
    "referencingMessageId": "…"
  }
}
```

## Error codes

| Code | Meaning | Recovery |
|---|---|---|
| `unauthorized` | Sender not in trusted list | Re-pair. |
| `invalidSignature` | Signature failed Ed25519 verify | Almost always client bug; iOS shows a diagnostics card. |
| `staleTimestamp` | Outside ±60 s window | Sync clocks; resend. |
| `replayedNonce` | Nonce already seen | Generate new nonce. |
| `unknownDevice` | Sender's device id not in store | Re-pair. |
| `revokedDevice` | Device was revoked | Re-pair. |
| `unsupportedProtocolVersion` | Version mismatch | Update one side. |
| `malformedPayload` | JSON shape failed to decode | Bug. |
| `sessionNotFound` | Session id unknown to Mac | Refresh `sessionListRequest`. |
| `approvalNotFound` / `approvalAlreadyDecided` / `approvalExpired` | Approval lifecycle violations | Refresh pending list. |
| `rateLimited` | Too many envelopes | Backoff. |
| `internalError` | Catch-all | Retry; check Mac diagnostics. |

## Versioning

`protocolVersion` is bumped any time the wire shape of an envelope, payload, or signing canon changes incompatibly. iOS shows a banner if its version doesn't match the Mac's; both sides refuse to operate cross-version. Additive changes (new optional fields, new payload types) do **not** bump the version.

## Constants (`ProtocolConstants`)

| Name | Default |
|---|---|
| `version` | 1 |
| `maxClockSkewSeconds` | 60 |
| `maxNonceCacheSize` | 4096 |
| `heartbeatIntervalSeconds` | 15 |
| `heartbeatTimeoutSeconds` | 45 |
| `approvalDefaultTimeoutSeconds` | 300 |
| `eventBackfillBatchSize` | 200 |
