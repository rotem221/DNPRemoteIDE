import Foundation
import CryptoKit

/// Ed25519 signing for `BridgeEnvelope`. Sign canonical JSON of the envelope with `signature == ""`.
public enum BridgeSigner {

    public static func sign<P: Codable & Hashable & Sendable>(
        envelope: inout BridgeEnvelope<P>,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws {
        envelope.signature = ""
        let bytes = try canonicalJSON(envelope)
        let sig = try privateKey.signature(for: bytes)
        envelope.signature = sig.base64EncodedString()
    }

    public static func verify<P: Codable & Hashable & Sendable>(
        envelope: BridgeEnvelope<P>,
        publicKey: Curve25519.Signing.PublicKey
    ) throws -> Bool {
        guard let sigData = Data(base64Encoded: envelope.signature) else {
            throw BridgeSecurityError.invalidSignatureEncoding
        }
        var unsigned = envelope
        unsigned.signature = ""
        let bytes = try canonicalJSON(unsigned)
        return publicKey.isValidSignature(sigData, for: bytes)
    }

    /// Canonical JSON: keys sorted, no whitespace, ISO-8601-with-fractional-seconds for `Date`.
    public static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601withFraction
        return try encoder.encode(value)
    }
}

public enum BridgeSecurityError: Error, Hashable, Sendable {
    case invalidSignatureEncoding
    case staleTimestamp
    case replayedNonce
    case unknownSender
    case revokedSender
    case unsupportedProtocolVersion
}

extension JSONEncoder.DateEncodingStrategy {
    /// ISO-8601 with milliseconds. Stable across platforms.
    public static var iso8601withFraction: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601DateFormatter.dnpShared.string(from: date))
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    public static var iso8601withFraction: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let d = ISO8601DateFormatter.dnpShared.date(from: s) { return d }
            // Fallback: plain ISO8601 without fractional seconds.
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let d = plain.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad ISO date: \(s)")
        }
    }
}

extension ISO8601DateFormatter {
    public static let dnpShared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
