import XCTest
import CryptoKit
@testable import DNPShared

final class BridgeEnvelopeTests: XCTestCase {

    func testEnvelopeRoundTripWithLiveEvent() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let pub  = priv.publicKey

        let event = SessionEvent(
            sessionId: UUID(), sequence: 1, type: .userMessage,
            severity: .info, source: .ios, title: "Hi",
            payload: .message(MessagePayload(role: .user, text: "Hello"))
        )
        var env = BridgeEnvelope<LiveEventPayload>(
            type: .liveEvent,
            senderId: UUID(),
            sessionId: event.sessionId,
            nonce: NonceFactory.make(),
            payload: LiveEventPayload(event: event)
        )
        try BridgeSigner.sign(envelope: &env, privateKey: priv)

        // Encode → decode → verify, simulating the wire.
        let bytes = try DNPCoders.encode(env)
        let restored = try DNPCoders.decode(BridgeEnvelope<LiveEventPayload>.self, from: bytes)
        XCTAssertTrue(try BridgeSigner.verify(envelope: restored, publicKey: pub))
        XCTAssertEqual(restored.payload.event.title, "Hi")
    }

    func testCanonicalEncodingIsStable() throws {
        let priv = Curve25519.Signing.PrivateKey()
        var env = BridgeEnvelope<HelloPayload>(
            type: .hello,
            senderId: UUID(),
            nonce: "AAAA====",
            payload: HelloPayload(deviceId: UUID(), deviceName: "x", platform: .iPhone, appVersion: "0.1")
        )
        try BridgeSigner.sign(envelope: &env, privateKey: priv)

        let one = try BridgeSigner.canonicalJSON(env)
        let two = try BridgeSigner.canonicalJSON(env)
        XCTAssertEqual(one, two, "canonical JSON must be byte-stable across calls")
    }

    func testProtocolVersionConstant() {
        XCTAssertEqual(ProtocolConstants.version, 1)
    }
}
