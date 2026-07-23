import XCTest
@testable import seahelm

/// Locks the E2EE wire contract shared with `clients/seahelm-web/e2ee.js`.
/// The password KAT vector below was produced by the JS module for the same
/// root secret — if HKDF drifts on either side, pairing/auth silently breaks.
final class MqttCryptoTests: XCTestCase {
    /// root_secret = 32 bytes 0x00…0x1f
    private let root = Data((0..<32).map { UInt8($0) })

    func testAuthPasswordKAT() {
        let c = MqttCrypto(rootSecret: root)
        // Cross-checked against e2ee.js deriveKeys(...).password
        XCTAssertEqual(c.authPassword,
                       "1f30db8b0e2f696aa5575f7eef0a05eb08b443df09bbad725e21f915b6abc26b")
    }

    func testSealOpenRoundTrip() {
        let c = MqttCrypto(rootSecret: root)
        let topic = "seahelm/testmac/pane/p1/status"
        let plain = #"{"status":"Running","seq":1}"#
        let sealed = c.seal(plain, topic: topic)
        XCTAssertFalse(sealed.isEmpty)
        XCTAssertNotEqual(sealed, plain)               // actually encrypted
        XCTAssertEqual(c.open(sealed, topic: topic), plain)
    }

    func testWrongTopicRejected() {
        let c = MqttCrypto(rootSecret: root)
        let sealed = c.seal("hello", topic: "seahelm/testmac/pane/p1/status")
        // topic is the GCM AAD → opening under a different topic must fail
        XCTAssertNil(c.open(sealed, topic: "seahelm/testmac/pane/p2/status"))
    }

    func testEmptyIsRetainedDeletePassthrough() {
        let c = MqttCrypto(rootSecret: root)
        XCTAssertEqual(c.seal("", topic: "t"), "")
        XCTAssertEqual(c.open("", topic: "t"), "")
    }

    func testPairURIRoundTrip() {
        let uri = MqttCrypto.pairURI(broker: "wss://x:8084/mqtt", macId: "testmac", rootSecret: root)
        XCTAssertTrue(uri.hasPrefix("seahelm://pair?"))
        // k= is base64url of the same root secret
        let k = uri.components(separatedBy: "k=").last ?? ""
        XCTAssertEqual(MqttCrypto.rootSecret(fromBase64url: k), root)
    }
}
