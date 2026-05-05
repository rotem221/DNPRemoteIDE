import Foundation
import CryptoKit
import Security

/// Owns the Mac's Ed25519 identity, list of trusted iOS devices, and pairing offers.
/// Keys persist in the macOS Keychain. Trusted devices persist as JSON.
actor DeviceTrustService {

    private(set) var macIdentity: Curve25519.Signing.PrivateKey?
    private(set) var macDeviceId: UUID = UUID()
    private(set) var trustedDevices: [DeviceRecord] = []

    /// Active pairing sessions, keyed by token.
    private var activeSessions: [String: PairingSession] = [:]
    /// Failed-attempt counter per humanCode (rate limiting; resets on success or expiry).
    private var failedAttempts: [String: Int] = [:]

    private let keychainAccount = "DNPRemoteMac.identity"
    private let macIdAccount = "DNPRemoteMac.deviceId"
    private let keychainService = "com.dnp.remote.mac"

    private let trustedDevicesURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DNPRemoteMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trusted-devices.json")
    }()

    func bootstrap() {
        // Persistent device id
        if let raw = readKeychain(account: macIdAccount), let s = String(data: raw, encoding: .utf8),
           let id = UUID(uuidString: s) {
            macDeviceId = id
        } else {
            let id = UUID(); macDeviceId = id
            writeKeychain(Data(id.uuidString.utf8), account: macIdAccount)
        }
        // Persistent identity
        if let existing = loadIdentity() {
            macIdentity = existing
        } else {
            let pk = Curve25519.Signing.PrivateKey()
            saveIdentity(pk)
            macIdentity = pk
        }
        loadTrustedDevices()
        // Janitor: expire old sessions every 60s.
        Task { [weak self] in
            while !(Task.isCancelled) {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                await self?.gcExpiredSessions()
            }
        }
    }

    // MARK: - Pairing offers

    /// Issue a new pairing offer. Returns the full session — caller renders QR + 6-digit.
    /// `tailscaleEndpoint` is optional secondary endpoint that the iPhone will fall back to
    /// when the LAN endpoint is unreachable. The caller probes `TailscaleService` and
    /// passes `ws://<tailnet-ipv4>:<port>` when Tailscale is up.
    func issuePairingSession(endpoint: String,
                             tailscaleEndpoint: String? = nil,
                             ttl: TimeInterval = 5 * 60) -> PairingSession {
        var raw = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
        let token = Data(raw).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        let code = HumanPairingCode.derive(from: token)
        let session = PairingSession(
            token: token,
            humanCode: code,
            endpoint: endpoint,
            tailscaleEndpoint: tailscaleEndpoint,
            macDeviceId: macDeviceId,
            macName: Self.machineName(),
            macPublicKey: macPublicKeyData(),
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(ttl)
        )
        activeSessions[token] = session
        return session
    }

    /// Cancel all pending pairing offers (e.g., user backed out of pairing UI).
    func cancelAllPairingSessions() {
        activeSessions.removeAll()
        failedAttempts.removeAll()
    }

    /// Validate a pairing attempt by the long token (came from QR).
    func acceptPairing(token: String, fromDevice req: PairingRequest) -> PairingResponse {
        guard let session = activeSessions[token], session.expiresAt > Date() else {
            return denyPairing(reason: "invalid or expired pairing token")
        }
        return finalizePairing(session: session, request: req)
    }

    /// Validate a pairing attempt by the 6-digit human code (typed manually).
    /// Rate-limited: 5 wrong attempts on a code burns it.
    func acceptPairing(humanCode: String, fromDevice req: PairingRequest) -> PairingResponse {
        let candidates = activeSessions.values.filter { $0.expiresAt > Date() }
        for session in candidates where HumanPairingCode.equals(session.humanCode, humanCode) {
            failedAttempts[session.humanCode] = nil
            return finalizePairing(session: session, request: req)
        }
        // Rate limit
        let count = (failedAttempts[humanCode] ?? 0) + 1
        failedAttempts[humanCode] = count
        if count >= 5 {
            // Burn any session with that code, if present.
            for (k, v) in activeSessions where v.humanCode == humanCode {
                activeSessions.removeValue(forKey: k)
            }
            return denyPairing(reason: "too many wrong attempts")
        }
        return denyPairing(reason: "code did not match")
    }

    private func finalizePairing(session: PairingSession, request req: PairingRequest) -> PairingResponse {
        activeSessions.removeValue(forKey: session.token)
        let fp = Self.fingerprint(of: req.publicKey)
        let device = DeviceRecord(
            id: req.deviceId, name: req.deviceName, platform: req.platform,
            publicKey: req.publicKey, fingerprint: fp,
            pairedAt: Date(), lastSeenAt: Date(),
            trusted: true, revoked: false
        )
        trustedDevices.removeAll(where: { $0.id == device.id })
        trustedDevices.append(device)
        saveTrustedDevices()
        return PairingResponse(
            accepted: true,
            macDeviceId: macDeviceId, macName: Self.machineName(),
            macPublicKey: macPublicKeyData(),
            issuedAt: Date(),
            serverEndpoint: session.endpoint
        )
    }

    private func denyPairing(reason: String) -> PairingResponse {
        PairingResponse(
            accepted: false,
            macDeviceId: macDeviceId, macName: Self.machineName(),
            macPublicKey: macPublicKeyData(),
            issuedAt: Date(),
            serverEndpoint: "",
            denialReason: reason
        )
    }

    private func gcExpiredSessions() {
        let now = Date()
        for (k, v) in activeSessions where v.expiresAt <= now {
            activeSessions.removeValue(forKey: k)
        }
    }

    // MARK: - Trusted devices

    func revoke(deviceId: UUID, reason: String?) {
        if let i = trustedDevices.firstIndex(where: { $0.id == deviceId }) {
            trustedDevices[i].revoked = true
            trustedDevices[i].trusted = false
            trustedDevices[i].notes = reason
            saveTrustedDevices()
        }
    }

    func touchLastSeen(deviceId: UUID) {
        if let i = trustedDevices.firstIndex(where: { $0.id == deviceId }) {
            trustedDevices[i].lastSeenAt = Date()
            saveTrustedDevices()
        }
    }

    /// Permanently forget a device — removes the trust record entirely (vs `revoke`, which keeps it
    /// with `revoked = true` for auditing). Future envelopes from this device will fail "unknownDevice".
    func forget(deviceId: UUID) {
        trustedDevices.removeAll(where: { $0.id == deviceId })
        saveTrustedDevices()
    }

    func publicKey(forDevice id: UUID) -> Curve25519.Signing.PublicKey? {
        guard let d = trustedDevices.first(where: { $0.id == id }), !d.revoked else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: d.publicKey)
    }

    func macPublicKeyData() -> Data { macIdentity?.publicKey.rawRepresentation ?? Data() }

    // MARK: - Helpers

    private static func machineName() -> String {
        Host.current().localizedName ?? "Mac"
    }

    private static func fingerprint(of key: Data) -> String {
        let digest = SHA256.hash(data: key)
        return digest.prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private func saveIdentity(_ key: Curve25519.Signing.PrivateKey) {
        writeKeychain(key.rawRepresentation, account: keychainAccount)
    }

    private func loadIdentity() -> Curve25519.Signing.PrivateKey? {
        guard let data = readKeychain(account: keychainAccount) else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    private func writeKeychain(_ data: Data, account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(q as CFDictionary)
        _ = SecItemAdd(q as CFDictionary, nil)
    }

    private func readKeychain(account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    private func loadTrustedDevices() {
        guard let data = try? Data(contentsOf: trustedDevicesURL),
              let list = try? DNPCoders.decode([DeviceRecord].self, from: data) else { return }
        trustedDevices = list
    }

    private func saveTrustedDevices() {
        if let data = try? DNPCoders.encode(trustedDevices) {
            try? data.write(to: trustedDevicesURL)
        }
    }
}
