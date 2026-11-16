import XCTest
@testable import seahelm

final class GatewaySettingsTests: XCTestCase {
    /// `gateway.config.get` carries the Bot API proxy as `telegram.api_url`.
    func testReadsTheTelegramAPIURL() {
        let s = GatewaySettings(["telegram": ["api_url": "https://tg-api.example.com", "enabled": true]])
        XCTAssertEqual(s.telegram.apiURL, "https://tg-api.example.com")
        XCTAssertNil(GatewaySettings(["telegram": ["enabled": true]]).telegram.apiURL)
    }
}
