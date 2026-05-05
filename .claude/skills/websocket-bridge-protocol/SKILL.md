---
name: websocket-bridge-protocol
description: Use when modifying the local Mac↔iOS bridge — typed BridgeEnvelope<P>, length-prefixed framing, message types, sequencing, heartbeat, reconnect. Triggers on changes to apps/DNPRemoteMac/DNPRemoteMac/Bridge/BridgeServerService.swift, apps/DNPRemoteiOS/DNPRemoteiOS/Bridge/BridgeClientService.swift, or DNPShared/Protocol/.
---

## When to use

Any change to the wire format, signing flow, sequencing, heartbeats, or reconnect behavior between Mac and iOS.

## Hard rules

- One TCP connection per iOS client. Bonjour-published `_dnp-remote._tcp` (planned); manual endpoint works today.
- Frame: `<u32 big-endian length><JSON envelope>`. Max 4 MB per frame.
- Each frame is exactly one `BridgeEnvelope<Payload>`, signed Ed25519 over canonical JSON with `signature == ""`.
- Canonical JSON: sorted keys, no escaped slashes, ISO-8601 with milliseconds. Use `DNPCoders` + `iso8601withFraction`.
- Per-session monotonic `sequence`. iOS subscribes with `lastSequenceSeen`; Mac backfills, then transitions to live.
- Heartbeat every 15 s; timeout 45 s. On timeout: drop, reconnect with exponential backoff (1, 2, 4, 8 s, capped 30 s).
- Errors travel as `BridgeErrorPayload` envelopes with a typed code (`BridgeErrorCode`), not as TCP socket closures.

## How to apply

### Frame helper

```swift
static func frame(_ data: Data) -> Data {
    var out = Data(capacity: data.count + 4)
    let len = UInt32(data.count).bigEndian
    withUnsafeBytes(of: len) { out.append(contentsOf: $0) }
    out.append(data)
    return out
}
```

### Send a signed envelope

```swift
var env = BridgeEnvelope<UserPromptPayload>(
    type: .userPrompt,
    senderId: deviceId,
    sessionId: sid,
    nonce: NonceFactory.make(),
    payload: UserPromptPayload(sessionId: sid, text: text)
)
try BridgeSigner.sign(envelope: &env, privateKey: keyService.privateKey)
let bytes = try DNPCoders.encode(env)
conn.send(content: Self.frame(bytes), completion: .contentProcessed { _ in })
```

### Receive loop

```swift
conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
    guard let self, let data, data.count == 4, error == nil else { self?.dropClient(id); return }
    let len = Int(UInt32(bigEndian: data.withUnsafeBytes { $0.load(as: UInt32.self) }))
    guard len > 0, len < 4 * 1024 * 1024 else { self.dropClient(id); return }
    conn.receive(minimumIncompleteLength: len, maximumLength: len) { payload, _, _, error in
        guard let payload, error == nil else { self.dropClient(id); return }
        self.onIncomingFrame?(payload, id)
        self.receiveLoop(connectionId: id)
    }
}
```

### Subscribe → backfill → live

```
iOS ─subscribeSession{ sid, lastSequenceSeen: 247 }─▶ Mac
Mac ─eventBatch{ events: [248..447], isBackfill: true, highestSequence: 447 }─▶ iOS
Mac ─eventBatch{ events: [448..N],   isBackfill: true, highestSequence: N   }─▶ iOS  (until caught up)
Mac ─liveEvent{ event: ... }                                                  ─▶ iOS  (continuous)
```

### Reconnect with exponential backoff

```swift
private var attempt = 0
func reconnect() {
    let delay = min(30.0, pow(2.0, Double(attempt)))
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.connect(...)
    }
    attempt += 1
}
```

## Examples

**Good** — typed payload + signed envelope:

```swift
var env = BridgeEnvelope<HeartbeatPayload>(type: .heartbeat, senderId: deviceId,
                                           nonce: NonceFactory.make(),
                                           payload: HeartbeatPayload(connectionUptimeSeconds: uptime))
try BridgeSigner.sign(envelope: &env, privateKey: priv)
```

**Bad** — sending raw JSON:

```swift
conn.send(content: rawJSON, completion: .contentProcessed { _ in })   // ❌ bypasses framing + signing
```

## Pitfalls

- Forgetting to zero `signature` before signing breaks verification on the other side.
- Sending two frames without resuming the receive loop deadlocks the second frame.
- Passing the receive loop's `data` directly to `JSONDecoder` without checking `len` lets a hostile sender wedge the decoder.
- Forgetting that `NWConnection.receive(minimumIncompleteLength:)` doesn't guarantee exactly-N reads on slow links — the API does fill, but always re-validate `data.count`.
