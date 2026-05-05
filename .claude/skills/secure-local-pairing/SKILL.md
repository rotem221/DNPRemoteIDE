---
name: secure-local-pairing
description: Use when implementing or modifying QR-code pairing, Ed25519 key generation, Keychain storage, or device revocation between DNP Remote Mac and DNP Remote iOS. Triggers on changes to apps/DNPRemoteMac/DNPRemoteMac/Pairing/, apps/DNPRemoteiOS/DNPRemoteiOS/Pairing/, or DNPShared/Security/.
---

## When to use

Any change to the pairing flow, key material, Keychain access, or device trust store.

## Hard rules

- Keys are Curve25519 (Ed25519), generated with `Curve25519.Signing.PrivateKey()` and persisted as the 32-byte raw representation.
- Keychain on Mac: `service: com.dnp.remote.mac`, `account: DNPRemoteMac.identity`. iOS: `service: com.dnp.remote.ios`, `account: ios.identity`.
- Pairing tokens: 16 random bytes, base64-encoded, slash-replaced for QR-friendliness, single-use, expire in 5 minutes.
- The Mac always requires an *explicit* user tap to approve an incoming pairing. No auto-accept.
- iOS stores the Mac's public key + endpoint after a successful pair. Future envelopes are verified against that key.
- Revocation flips `revoked = true`, clears the nonce cache for that sender, and drops the connection.
- No hardcoded secrets. No keys in logs.

## How to apply

### Generate / load identity

```swift
private func loadOrCreateIdentity() -> Curve25519.Signing.PrivateKey {
    if let raw = readKeychain(account: keyAccount, service: keyService),
       let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
        return key
    }
    let key = Curve25519.Signing.PrivateKey()
    writeKeychain(key.rawRepresentation, account: keyAccount, service: keyService)
    return key
}
```

### Issue pairing token (Mac)

```swift
func issuePairingToken() -> String {
    let token = NonceFactory.make().replacingOccurrences(of: "/", with: "_")
    activePairingTokens.insert(token)
    Task { try? await Task.sleep(nanoseconds: 300 * 1_000_000_000); expireToken(token) }
    return token
}
```

### Pairing handshake

```
   iOS ──pairingRequest{ token, deviceId, name, iosPubKey }──▶ Mac
   Mac ── show local "Approve incoming device?" ──▶ user
   Mac ── on approve, store DeviceRecord(trusted: true) ─────
   Mac ──pairingResponse{ macDeviceId, macName, macPubKey, endpoint }──▶ iOS
   iOS ── store PairedMacInfo, ready to verify future envelopes
```

### Fingerprint for the UI

```swift
static func fingerprint(of key: Data) -> String {
    let digest = SHA256.hash(data: key)
    return digest.prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
}
```

### Revocation

```swift
func revoke(deviceId: UUID, reason: String?) {
    if let i = trustedDevices.firstIndex(where: { $0.id == deviceId }) {
        trustedDevices[i].revoked = true
        trustedDevices[i].trusted = false
        saveTrustedDevices()
    }
    replayProtection.forget(senderId: deviceId)
    bridge.dropConnections(forSender: deviceId)
}
```

## Examples

**Good** — keychain item created with `kSecAttrAccessible` set tight (planned):

```swift
let q: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: keyService,
    kSecAttrAccount as String: keyAccount,
    kSecValueData as String: data,
    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
]
```

**Bad** — embedding shared secret:

```swift
let SHARED_KEY = Data("hunter2".utf8)   // ❌ never
```

## Pitfalls

- Forgetting to delete the existing item before `SecItemAdd` results in `errSecDuplicateItem`. Always `SecItemDelete` first when overwriting.
- Treating the pairing token like a long-term credential. It's single-use, short-lived. Discard after the response is sent.
- Not handling `Curve25519.Signing.PrivateKey(rawRepresentation:)` throwing. Wrap in `try?` and regenerate if corrupt.
- Storing the Mac's endpoint in `UserDefaults` only — fine for now, but plan for Bonjour discovery so endpoints are dynamic.
