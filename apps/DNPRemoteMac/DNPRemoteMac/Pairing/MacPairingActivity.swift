import Foundation

/// Live state of an in-progress pairing attempt as observed from the Mac side.
/// Surfaced in `PairingSheet` so the Mac mirrors the same "Connecting → Verifying →
/// Paired / Failed" feedback the iPhone already shows in `PairingView`.
enum MacPairingActivity: Equatable {
    /// No iPhone is mid-handshake.
    case idle
    /// A TCP connection landed but no pairing request has been decoded yet.
    /// `remote` is the iPhone's endpoint (host:port), useful for confirming "yes that's mine".
    case connecting(remote: String)
    /// Pairing request decoded; the Mac is validating the code/token and the
    /// iOS Ed25519 key. `deviceName` comes from the request (e.g. "Rotem's iPhone").
    /// `via` distinguishes scan-QR (`.token`) from manual 6-digit entry (`.humanCode`).
    case verifying(deviceName: String, via: Channel)
    /// Handshake succeeded. The success overlay in PairingSheet shows for ~1.6s
    /// before the sheet auto-dismisses, so this state is mostly diagnostic.
    case succeeded(deviceName: String, fingerprint: String)
    /// Pairing was rejected — wrong code, expired token, or signature mismatch.
    case failed(reason: String)

    enum Channel: Equatable {
        case token       // QR scan
        case humanCode   // typed 6-digit code
    }
}
