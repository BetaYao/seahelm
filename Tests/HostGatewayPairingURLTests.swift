import XCTest
@testable import seahelm

final class HostGatewayPairingURLTests: XCTestCase {
    func testPrefersHostGatewayWhenEnabled() {
        let hg = HostGatewayConfig(enabled: true, port: 2783, publicURL: "wss://x/ws")
        var mqtt = MqttConfig(host: "127.0.0.1")
        mqtt.clientBroker = "wss://gw.seahelm.dev/mqtt"
        XCTAssertEqual(
            HostGatewayPairing.clientEntryURL(hostGateway: hg, mqtt: mqtt),
            "wss://x/ws")
    }

    func testFallsBackToMqttWhenGatewayDisabled() {
        let hg = HostGatewayConfig(enabled: false, publicURL: "wss://x/ws")
        var mqtt = MqttConfig(host: "127.0.0.1")
        mqtt.clientBroker = "wss://gw.seahelm.dev/mqtt"
        XCTAssertEqual(
            HostGatewayPairing.clientEntryURL(hostGateway: hg, mqtt: mqtt),
            "wss://gw.seahelm.dev/mqtt")
    }

    func testFallsBackWhenHostGatewayNil() {
        var mqtt = MqttConfig(host: "gw.seahelm.dev")
        mqtt.tls = true
        mqtt.websocket = true
        mqtt.port = 443
        mqtt.wsPath = "/mqtt"
        XCTAssertEqual(
            HostGatewayPairing.clientEntryURL(hostGateway: nil, mqtt: mqtt),
            "wss://gw.seahelm.dev/mqtt")
    }

    func testDefaultLocalhostGatewayURL() {
        let hg = HostGatewayConfig(enabled: true)
        XCTAssertEqual(
            HostGatewayPairing.clientEntryURL(hostGateway: hg, mqtt: nil),
            "ws://127.0.0.1:2783/ws")
    }

    func testMqttNilFallbackUsesEdgeDefault() {
        let hg = HostGatewayConfig(enabled: false)
        XCTAssertEqual(
            HostGatewayPairing.clientEntryURL(hostGateway: hg, mqtt: nil),
            "wss://gw.seahelm.dev/mqtt")
    }
}
