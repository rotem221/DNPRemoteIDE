---
name: testing-swift-suite
description: Use when adding XCTest coverage — shared models, parser fixtures, bridge envelope fuzz, approval round-trip, persistence recovery, UI snapshot smoke tests. Triggers on changes under Tests/ directories or when shipping behavioral code without coverage.
---

## When to use

Anywhere code without a corresponding test is being added or modified. Default expectation: every behavioral change has at least one positive and one negative test.

## Hard rules

- Tests live next to the module they test (`Packages/DNPShared/Tests/DNPSharedTests/` for shared; `apps/*/...Tests/` once added).
- Use plain XCTest. Avoid heavy frameworks. Snapshot tests can use a light third-party lib if added to a single test target only.
- Fixtures (PTY captures, hook JSON) live under `Tests/Fixtures/`. Each fixture has a one-line header in `Tests/Fixtures/README.md` explaining its provenance.
- Don't `XCTSkip` to hide flakes — fix the test or the code.
- Don't `Thread.sleep` outside of explicit timing tests; use `XCTestExpectation`.
- Tests that touch the keychain create + delete their own items in `setUp` / `tearDown` and use a unique `service` name.

## How to apply

### Codable round-trip

```swift
func testSessionRoundTrip() throws {
    let s = Session(title: "x", projectPath: "/tmp", projectName: "x")
    let data = try DNPCoders.encode(s)
    let restored = try DNPCoders.decode(Session.self, from: data)
    XCTAssertEqual(s, restored)
}
```

### Signature verify + tamper

```swift
func testTamperedPayloadFailsVerification() throws {
    let priv = Curve25519.Signing.PrivateKey(); let pub = priv.publicKey
    var env = BridgeEnvelope<HeartbeatPayload>(type: .heartbeat, senderId: UUID(),
                                               nonce: NonceFactory.make(),
                                               payload: HeartbeatPayload(connectionUptimeSeconds: 5))
    try BridgeSigner.sign(envelope: &env, privateKey: priv)
    var t = env; t.payload = HeartbeatPayload(connectionUptimeSeconds: 9999)
    XCTAssertFalse(try BridgeSigner.verify(envelope: t, publicKey: pub))
}
```

### Replay rejection

```swift
func testReplayProtection() {
    let rp = ReplayProtection(); let s = UUID(); let n = NonceFactory.make()
    XCTAssertEqual(rp.accept(senderId: s, nonce: n, timestamp: Date()).get(), ())
    if case .failure(let e) = rp.accept(senderId: s, nonce: n, timestamp: Date()) {
        XCTAssertEqual(e, .replayedNonce)
    } else { XCTFail("replay should fail") }
}
```

### Parser fixture

```swift
func testParserOnNpmInstallFixture() throws {
    let bytes = try Data(contentsOf: fixturesURL.appendingPathComponent("pty-npm-install.txt"))
    let normalizer = EventNormalizerService()
    let events = normalizer.ingest(rawPTY: bytes, sessionId: UUID())
    XCTAssertEqual(events.first?.type, .commandStarted)
    XCTAssertEqual(events.last?.type,  .commandCompleted)
}
```

### Approval round-trip

```swift
func testApprovalLifecycle() async {
    let coord = ApprovalCoordinator()
    let req = ApprovalRequest(sessionId: UUID(), actionType: .bashCommand, target: "ls",
                              summary: "List", risk: .low,
                              timeoutAt: Date().addingTimeInterval(60))
    await coord.create(req)
    await coord.markSentToIOS(req.id)
    let response = ApprovalResponse(approvalId: req.id, sessionId: req.sessionId,
                                    decision: .approve, deviceId: UUID())
    let result = await coord.apply(response)
    if case .accepted(let approved) = result { XCTAssertEqual(approved.status, .approved) }
    else { XCTFail() }
}
```

### Persistence recovery

```swift
func testRestartRestoresEvents() async throws {
    let svc = SessionPersistenceService()
    let sid = UUID()
    let event = makeUserEvent(sid: sid)
    await svc.appendEvent(event)
    // Simulate restart by spinning a fresh service
    let svc2 = SessionPersistenceService()
    let restored = try await svc2.eventsRestoredFromDisk(for: sid)
    XCTAssertEqual(restored, [event])
}
```

## Examples

**Good** — uses real CryptoKit:

```swift
let priv = Curve25519.Signing.PrivateKey()    // hits the real path
```

**Bad** — mocking what you want to test:

```swift
let signer = MockSigner(returns: .success)    // ❌ would test nothing
```

## Pitfalls

- Heavy `setUp` that touches the file system unbounded — clean up in `tearDown`.
- Time-dependent tests (e.g., expiry). Use a clock injection: `ReplayProtection(now: { fakeClock.value })`.
- Tests that depend on Bonjour discovery — guard with `XCTSkipIfRunningInCI`.
- UI snapshot tests that fail on each Xcode tweak — keep them to 1–2 happy paths per app.
