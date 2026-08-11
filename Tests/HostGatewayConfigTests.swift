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

    func testHostGatewayEncodeRoundTrip() throws {
        let hg = HostGatewayConfig(enabled: true, port: 2783, publicURL: "wss://x/ws")
        let data = try JSONEncoder().encode(hg)
        let decoded = try JSONDecoder().decode(HostGatewayConfig.self, from: data)
        XCTAssertEqual(decoded, hg)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["public_url"] as? String, "wss://x/ws")
    }
}
