import Foundation

/// iOS → Mac: unlock the Mac's lock screen by typing the supplied
/// password and pressing Return. The Mac side wakes the display
/// (`caffeinate -u -t 1`), types the password through `CGEvent`'s
/// unicode keystroke API, and submits.
///
/// The password is never persisted on the Mac side — it is consumed
/// once per request, dropped from memory, and never written to logs.
/// On the iOS side (a separate companion app, distributed via the
/// App Store) it lives only in the device Keychain when the user
/// opts to save it.
public struct MacUnlockRequestPayload: Codable, Hashable, Sendable {
    public let password: String
    public init(password: String) {
        self.password = password
    }
}

/// Mac → iOS: ack/error for a `MacUnlockRequest`. We deliberately keep
/// `reason` short and human-readable rather than mapping to a structured
/// error code — the only iOS-side action on failure is showing the user
/// a single banner, so the additional detail isn't worth a wire enum.
public struct MacUnlockResponsePayload: Codable, Hashable, Sendable {
    public let ok: Bool
    public let reason: String?
    public init(ok: Bool, reason: String? = nil) {
        self.ok = ok
        self.reason = reason
    }
}
