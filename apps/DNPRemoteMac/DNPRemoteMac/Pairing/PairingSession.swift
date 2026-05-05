import Foundation

/// One active pairing offer presented by the Mac. Contains everything the iPhone needs to identify this Mac
/// and establish a verified, signed connection.
///
/// Two ways to consume:
/// 1. Scan the QR code → JSON payload (`PairingSession.qrPayload`).
/// 2. Type the 6-digit `humanCode` + the Mac's IP/port manually.
struct PairingSession: Codable, Hashable, Sendable {
    let token: String              // 16 random bytes, base64 — high-entropy primary credential
    let humanCode: String          // 6-digit numeric, derived from the token (for manual entry)
    let endpoint: String           // ws://192.168.1.5:18733  (LAN)
    /// Optional secondary endpoint over Tailscale, populated when the Mac detects a running
    /// Tailscale daemon at QR-issue time. Carried in the QR under key `te`. The iPhone tries
    /// the LAN endpoint first; if it can't connect within ~8 s it retries against this one.
    /// That's what makes pairing work when both devices are on a hotel/coffee-shop network
    /// where the Mac's RFC1918 IP isn't reachable from the phone but the tailnet is.
    let tailscaleEndpoint: String?
    let macDeviceId: UUID
    let macName: String
    let macPublicKey: Data         // raw 32-byte Ed25519 public key
    let issuedAt: Date
    let expiresAt: Date

    /// JSON encoded into the QR code. Must remain compact; QR capacity is limited.
    /// `te` is omitted when the Mac doesn't have a tailnet IP, keeping the QR small for
    /// users who only ever pair on LAN.
    var qrPayload: String {
        var dict: [String: Any] = [
            "v": 1,
            "t": token,
            "c": humanCode,
            "e": endpoint,
            "id": macDeviceId.uuidString,
            "n": macName,
            "k": macPublicKey.base64EncodedString()
        ]
        if let te = tailscaleEndpoint, !te.isEmpty { dict["te"] = te }
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Decode a scanned QR payload. Returns `nil` for invalid/foreign payloads.
    static func fromQRPayload(_ s: String) -> ScannedPairing? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["v"] as? Int) == 1,
              let token = obj["t"] as? String,
              let code = obj["c"] as? String,
              let endpoint = obj["e"] as? String,
              let idString = obj["id"] as? String, let id = UUID(uuidString: idString),
              let name = obj["n"] as? String,
              let keyB64 = obj["k"] as? String, let key = Data(base64Encoded: keyB64)
        else { return nil }
        let te = obj["te"] as? String
        return ScannedPairing(token: token, humanCode: code, endpoint: endpoint,
                              tailscaleEndpoint: (te?.isEmpty == false) ? te : nil,
                              macDeviceId: id, macName: name, macPublicKey: key)
    }
}

/// What the iOS scanner produces after parsing a QR. Mirrors the relevant subset of `PairingSession`.
struct ScannedPairing: Codable, Hashable, Sendable {
    let token: String
    let humanCode: String
    let endpoint: String
    let tailscaleEndpoint: String?
    let macDeviceId: UUID
    let macName: String
    let macPublicKey: Data
}

/// Helpers for deriving + validating the 6-digit human code.
enum HumanPairingCode {

    /// Stable derivation: first 6 digits of SHA-256(token), as a string. Same token → same code.
    static func derive(from token: String) -> String {
        let data = Data(token.utf8)
        let digest = SHA256Helper.hex(of: data)
        let digits = digest.unicodeScalars.compactMap { c -> String? in
            (c.value >= 0x30 && c.value <= 0x39) ? String(c) : nil
        }.joined()
        let pool = digits.count >= 6 ? String(digits.prefix(6)) : (digits + String(repeating: "0", count: 6))
        return String(pool.prefix(6))
    }

    /// Constant-time-ish comparison.
    static func equals(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a.utf8, b.utf8) { diff |= x ^ y }
        return diff == 0
    }
}

/// Tiny SHA-256 wrapper to avoid pulling CryptoKit into a struct that doesn't otherwise need it.
import CryptoKit
enum SHA256Helper {
    static func hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
