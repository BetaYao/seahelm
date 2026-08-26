import XCTest
@testable import seahelm

final class HostGatewayConfigTests: XCTestCase {
    func testDefaultsWhenKeyMissing() throws {
        let cfg = try JSONDecoder().decode(HostGatewayConfig?.self, from: Data("null".utf8))
        XCTAssertNil(cfg)
        let hg = HostGatewayConfig()
        XCTAssertFalse(hg.resolvedEnabled)
        XCTAssertEqual(hg.resolvedPort, 2783)
        XCTAssertEqual(hg.resolvedPublicURL, "ws://127.0.0.1:2783/ws")
    }

    func testPublicURLOverride() {
        var hg = HostGatewayConfig()
        hg.publicURL = "wss://seahelm.example.com/ws"
        hg.port = 9
        XCTAssertEqual(hg.resolvedPublicURL, "wss://seahelm.example.com/ws")
    }

    func testLegacyConfigLeavesHostGatewayNil() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertNil(config.hostGateway)
    }

    func testConfigDecodesHostGateway() throws {
        let json = Data(#"""
        {
          "workspace_paths": [],
          "active_workspace_index": 0,
          "host_gateway": {
            "enabled": true,
            "port": 3001,
            "public_url": "wss://tunnel.example/ws"
          }
        }
        """#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(config.hostGateway?.enabled, true)
        XCTAssertEqual(config.hostGateway?.port, 3001)
        XCTAssertEqual(config.hostGateway?.resolvedPublicURL, "wss://tunnel.example/ws")
    }

    // MARK: - Settings fields

    func testEditedKeepsStoredPortWhenTheFieldIsNotAPort() {
        let existing = HostGatewayConfig(enabled: false, port: 2783, publicURL: "wss://x/ws")
        for junk in ["", "abc", "99999", "-1", "0"] {
            let edited = HostGatewayConfig.edited(enabled: true, portText: junk,
                                                  publicURLText: "wss://x/ws", from: existing)
            XCTAssertEqual(edited.port, 2783, "\(junk.debugDescription) should not have moved the port")
        }
    }

    func testEditedStoresBlankPublicURLAsNilSoItDerivesFromThePort() {
        let edited = HostGatewayConfig.edited(enabled: true, portText: "3000",
                                              publicURLText: "   ", from: nil)
        XCTAssertNil(edited.publicURL)
        XCTAssertEqual(edited.resolvedPublicURL, "ws://127.0.0.1:3000/ws")
    }

    /// The web root has no field, so rebuilding the struct from the page must not
    /// erase a working copy someone pointed at by hand.
    func testEditedCarriesTheWebRootThroughUntouched() {
        let existing = HostGatewayConfig(enabled: true, port: 2783, publicURL: nil,
                                         webRoot: "~/src/seahelm-web")
        let edited = HostGatewayConfig.edited(enabled: false, portText: "2783",
                                              publicURLText: "", from: existing)
        XCTAssertEqual(edited.webRoot, "~/src/seahelm-web")
        XCTAssertFalse(edited.resolvedEnabled)
    }

    func testEditedTrimsTheTypedPublicURL() {
        let edited = HostGatewayConfig.edited(enabled: true, portText: " 2783 ",
                                              publicURLText: "  wss://gw.example/ws  ", from: nil)
        XCTAssertEqual(edited.port, 2783)
        XCTAssertEqual(edited.publicURL, "wss://gw.example/ws")
        XCTAssertEqual(edited.resolvedPageURL, "https://gw.example/")
    }

    func testHostGatewayEncodeRoundTrip() throws {
        let hg = HostGatewayConfig(enabled: true, port: 2783, publicURL: "wss://x/ws")
        let data = try JSONEncoder().encode(hg)
        let decoded = try JSONDecoder().decode(HostGatewayConfig.self, from: data)
        XCTAssertEqual(decoded, hg)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["public_url"] as? String, "wss://x/ws")
    }
}
