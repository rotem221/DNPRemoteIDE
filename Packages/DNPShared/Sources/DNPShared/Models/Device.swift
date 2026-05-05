import Foundation

public struct DeviceRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var platform: DevicePlatform
    public var publicKey: Data            // Ed25519 raw representation, 32 bytes.
    public var fingerprint: String        // Short human-readable fingerprint.
    public var pairedAt: Date
    public var lastSeenAt: Date?
    public var trusted: Bool
    public var revoked: Bool
    public var notes: String?

    public init(
        id: UUID = UUID(),
        name: String,
        platform: DevicePlatform,
        publicKey: Data,
        fingerprint: String,
        pairedAt: Date = Date(),
        lastSeenAt: Date? = nil,
        trusted: Bool = false,
        revoked: Bool = false,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.pairedAt = pairedAt.dnpQuantized
        self.lastSeenAt = lastSeenAt?.dnpQuantized
        self.trusted = trusted
        self.revoked = revoked
        self.notes = notes
    }
}

public enum DevicePlatform: String, Codable, Hashable, Sendable {
    case iPhone, iPad, mac, unknown
}

public struct PairingRequest: Codable, Hashable, Sendable {
    public let pairingToken: String       // single-use, short-lived, Mac-issued
    public let deviceId: UUID
    public let deviceName: String
    public let platform: DevicePlatform
    public let publicKey: Data
    public let timestamp: Date
    public init(pairingToken: String, deviceId: UUID, deviceName: String, platform: DevicePlatform, publicKey: Data, timestamp: Date = Date()) {
        self.pairingToken = pairingToken; self.deviceId = deviceId; self.deviceName = deviceName
        self.platform = platform; self.publicKey = publicKey; self.timestamp = timestamp.dnpQuantized
    }
}

public struct PairingResponse: Codable, Hashable, Sendable {
    public let accepted: Bool
    public let macDeviceId: UUID
    public let macName: String
    public let macPublicKey: Data
    public let issuedAt: Date
    public let serverEndpoint: String     // ws://host:port
    public let denialReason: String?
    public init(accepted: Bool, macDeviceId: UUID, macName: String, macPublicKey: Data, issuedAt: Date = Date(), serverEndpoint: String, denialReason: String? = nil) {
        self.accepted = accepted; self.macDeviceId = macDeviceId; self.macName = macName
        self.macPublicKey = macPublicKey; self.issuedAt = issuedAt.dnpQuantized
        self.serverEndpoint = serverEndpoint; self.denialReason = denialReason
    }
}

public enum ConnectionStatus: String, Codable, Hashable, Sendable {
    case offline
    case discovering
    case connecting
    case authenticating
    case connected
    case degraded
    case error
}
