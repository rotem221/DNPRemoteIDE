import XCTest
import CryptoKit
@testable import DNPShared

final class SigningTests: XCTestCase {

    func testSignAndVerifyHelloEnvelope() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = priv.publicKey

        var env = BridgeEnvelope<HelloPayload>(
            type: .hello,
            senderId: UUID(),
            nonce: NonceFactory.make(),
            payload: HelloPayload(deviceId: UUID(), deviceName: "iPhone", platform: .iPhone, appVersion: "0.1")
        )
        try BridgeSigner.sign(envelope: &env, privateKey: priv)
        XCTAssertFalse(env.signature.isEmpty)
        let ok = try BridgeSigner.verify(envelope: env, publicKey: pub)
        XCTAssertTrue(ok)
    }

    func testTamperedPayloadFailsVerification() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = priv.publicKey

        var env = BridgeEnvelope<HeartbeatPayload>(
            type: .heartbeat,
            senderId: UUID(),
            nonce: NonceFactory.make(),
            payload: HeartbeatPayload(connectionUptimeSeconds: 5)
        )
        try BridgeSigner.sign(envelope: &env, privateKey: priv)

        // Tamper: re-create with different uptime, keep signature.
        let tampered = BridgeEnvelope<HeartbeatPayload>(
            id: env.id,
            type: env.type,
            senderId: env.senderId,
            timestamp: env.timestamp,
            nonce: env.nonce,
            signature: env.signature,
            payload: HeartbeatPayload(sentAt: env.payload.sentAt, connectionUptimeSeconds: 9999)
        )
        let ok = try BridgeSigner.verify(envelope: tampered, publicKey: pub)
        XCTAssertFalse(ok)
    }

    func testReplayProtectionRejectsRepeatedNonce() {
        let rp = ReplayProtection()
        let sender = UUID()
        let nonce = NonceFactory.make()
        let now = Date()
        switch rp.accept(senderId: sender, nonce: nonce, timestamp: now) {
        case .success: break
        case .failure(let e): XCTFail("first accept should succeed: \(e)")
        }
        switch rp.accept(senderId: sender, nonce: nonce, timestamp: now) {
        case .success: XCTFail("replay should fail")
        case .failure(let e): XCTAssertEqual(e, .replayedNonce)
        }
    }

    func testReplayProtectionRejectsStaleTimestamp() {
        let rp = ReplayProtection()
        let result = rp.accept(senderId: UUID(), nonce: NonceFactory.make(), timestamp: Date(timeIntervalSinceNow: -3600))
        switch result {
        case .success: XCTFail("stale timestamp should be rejected")
        case .failure(let e): XCTAssertEqual(e, .staleTimestamp)
        }
    }
}
