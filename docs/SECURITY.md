# Security — DNP Remote Suite

## Goals

1. The iPhone never executes shell or modifies files. It only views events and decides on approvals.
2. Only devices the user has explicitly paired can connect to the Mac bridge.
3. Every message between Mac and iOS is integrity-protected and replay-protected.
4. Compromised iPhone ⇒ revoke. Mac immediately stops accepting envelopes from that device id.
5. We respect Claude Code's permission model. iOS approvals translate into real `permissionDecision` values; we never bypass.

## Identities

| Identity | Material | Storage |
|---|---|---|
| Mac | Curve25519 (Ed25519) signing key, 32 bytes raw | macOS Keychain (`service: com.dnp.remote.mac`, `account: DNPRemoteMac.identity`) |
| iOS | Curve25519 (Ed25519) signing key | iOS Keychain (`service: com.dnp.remote.ios`, `account: ios.identity`) |
| Device id | UUID per device, persisted alongside the key | Same Keychain item set |

Identities are generated on first launch and never leave the device.

## Pairing

```
   ┌────────────┐                                      ┌────────────┐
   │ DNP Mac    │                                      │ DNP iOS    │
   └─────┬──────┘                                      └─────┬──────┘
         │ 1. User taps "New Pairing Code"                  │
         │ 2. Mac issues single-use token (5-min expiry)    │
         │ 3. Render QR{ token, endpoint, macPubKey }       │
         │                                                   │
         │  ──────── QR scanned by iOS camera ────────────▶ │
         │                                                   │
         │ 4. iOS sends pairingRequest envelope              │
         │    { token, deviceId, deviceName, iosPubKey }     │
         │   signed by iOS                                   │
         │ ◀─────────────────────────────────────────────── │
         │                                                   │
         │ 5. Mac verifies: token present + not used         │
         │ 6. Mac shows local "Approve incoming device" UI  │
         │ 7. On user OK: store device record (trusted=true)│
         │ 8. Mac sends pairingResponse                      │
         │    { accepted, macDeviceId, macName, macPubKey,   │
         │      endpoint }                                   │
         │   signed by Mac                                   │
         │ ─────────────────────────────────────────────────▶│
         │                                                   │
         │ 9. iOS stores macPublicKey for future verify      │
         │10. Token consumed                                 │
```

Constraints:
- The pairing token is 16 random bytes (base64, slash-replaced for QR friendliness) and consumed on first use.
- Token expires after 5 minutes if unused.
- iOS still has to be approved on the Mac itself ("user is present" requirement).
- After pairing, the token is forgotten.

## Envelope signing

All non-pairing traffic is `BridgeEnvelope<P>` where `P` is the typed payload. The envelope is signed Ed25519 over the canonical JSON of the envelope with `signature == ""`.

Canonical JSON rules (`DNPShared/Security/Signing.swift` + `Coders.swift`):
- Keys sorted lexicographically (`JSONEncoder.OutputFormatting.sortedKeys`).
- No escaped slashes (`.withoutEscapingSlashes`).
- Dates as ISO-8601 with milliseconds, UTC ("Z" suffix), via `iso8601withFraction`.
- No whitespace.

Per-envelope binding fields:
- `id` (UUID per message)
- `senderId` (device id)
- `recipientId` (optional; used when broadcasting to a specific client)
- `sessionId` (optional; ties payload to a session)
- `nonce` (16 bytes, base64)
- `timestamp` (Date)

## Replay protection

`ReplayProtection` maintains an LRU of seen nonces per `senderId`. Defaults:
- 4 096 nonces per sender (`ProtocolConstants.maxNonceCacheSize`).
- ±60 s timestamp window (`ProtocolConstants.maxClockSkewSeconds`).

Verification rejects the envelope if any of the following fails:
- Signature doesn't validate against the sender's stored public key.
- Sender is unknown or revoked.
- Timestamp is outside the skew window (`.staleTimestamp`).
- Nonce was already seen (`.replayedNonce`).
- Protocol version mismatch (`.unsupportedProtocolVersion`).

## Approval binding

Each `ApprovalResponse` envelope must:
- Reference an existing `approvalId` whose status is **not** terminal.
- Match the `sessionId` of that approval.
- Be signed by a trusted device that is the same one (or any trusted device — multi-device decisions are allowed by design; first valid response wins).

`ApprovalCoordinator.apply` is the only place that mutates approval state once decided; subsequent responses get `BridgeErrorCode.approvalAlreadyDecided`.

## Device revocation

Revoking a device:
1. Marks `DeviceRecord.revoked = true`, `trusted = false` in the trusted-device store.
2. `BridgeServer` drops the connection if the revoked device is currently connected.
3. `ReplayProtection.forget(senderId)` clears its nonce cache.
4. Future envelopes from that device are rejected with `BridgeErrorCode.revokedDevice`.

## Threat model

| Threat | Mitigation |
|---|---|
| Rogue device on the same Wi-Fi | Only paired/trusted devices have a valid public key. Unsigned/forged envelopes fail verify. |
| Replay of recorded envelope | Nonce LRU + timestamp window. |
| Tampered envelope (bit flip in `payload`) | Signature is over the whole canonical JSON. |
| Stolen iPhone | User revokes the device on the Mac. Optionally: enable iOS biometrics gate before a decision is sent (planned). |
| Malicious project files | Claude Code's permission model gates risky tools; iOS approvals are the second wall. |
| Hook relay tampering | Relay is local and runs as the same user. Mac validates events by source = `.hookRelay` and stamps a local sequence number on each. |
| MitM between iPhone & Mac | Default transport is `acceptLocalOnly` TCP on the LAN; signing covers integrity. TLS-on-LAN is a planned hardening. |

## Out of scope (non-goals)

- Cross-WAN remote control. Suite is local-LAN only.
- Multi-tenant Mac (sharing one Mac across multiple isolated user spaces).
- Cryptographic deniability or anonymous pairing.

## Defense-in-depth checklist

- [x] Keys never leave the originating device.
- [x] Settings file at `.claude/settings.json` is committed; secrets live only in `.claude/settings.local.json` (gitignored).
- [x] No `--dangerously-skip-permissions` in any default launch path.
- [x] Pairing requires user presence on the Mac.
- [x] Hook relay is fail-open but logs every drop.
- [ ] TLS-on-LAN (`tls_proto`) — planned.
- [ ] Biometric gate on iOS approvals — planned.
- [ ] Per-session "review-only" mode where iOS cannot approve, only view — planned.
