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

    func testClientBrokerOverride() {
        var m = MqttConfig(host: "127.0.0.1")
        m.port = 1883
        m.tls = false
        m.websocket = false
        m.clientBroker = "wss://gw.seahelm.dev/mqtt"
        XCTAssertEqual(m.resolvedClientBrokerURL, "wss://gw.seahelm.dev/mqtt")
    }

    func testClientBrokerOmitsStandardHTTPSPort() {
        var m = MqttConfig(host: "gw.seahelm.dev")
        m.port = 443
        m.tls = true
        m.websocket = true
        m.wsPath = "/mqtt"
        XCTAssertEqual(m.resolvedClientBrokerURL, "wss://gw.seahelm.dev/mqtt")
    }

    func testClientBrokerKeepsNonStandardPort() {
        var m = MqttConfig(host: "broker.example")
        m.port = 8084
        m.tls = true
        m.websocket = true
        XCTAssertEqual(m.resolvedClientBrokerURL, "wss://broker.example:8084/mqtt")
    }

    func testNormalizeMqttRetargetsEmqxCloud() {
        var mqtt: MqttConfig? = MqttConfig(host: "a81fb6d3.ala.cn-hangzhou.emqxsl.cn")
        mqtt?.port = 8084
        mqtt?.tls = true
        mqtt?.websocket = true
        mqtt?.rootSecret = "keep-me"
        mqtt?.macId = "live"
        MqttConfig.normalizeForEdgeStack(&mqtt)
        XCTAssertEqual(mqtt?.host, "127.0.0.1")
        XCTAssertEqual(mqtt?.port, 1883)
        XCTAssertEqual(mqtt?.tls, false)
        XCTAssertEqual(mqtt?.websocket, false)
        XCTAssertEqual(mqtt?.clientBroker, "wss://gw.seahelm.dev/mqtt")
        XCTAssertEqual(mqtt?.rootSecret, "keep-me")
        XCTAssertEqual(mqtt?.macId, "live")
        XCTAssertEqual(mqtt?.resolvedClientBrokerURL, "wss://gw.seahelm.dev/mqtt")
    }
}
