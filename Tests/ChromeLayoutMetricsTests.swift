import XCTest
@testable import seahelm

final class ChromeLayoutMetricsTests: XCTestCase {
    func testClampSidebarWidth() {
        XCTAssertEqual(ChromeLayoutMetrics.clampWidth(100, windowWidth: 1000), 200)
        XCTAssertEqual(ChromeLayoutMetrics.clampWidth(300, windowWidth: 1000), 300)
        XCTAssertEqual(ChromeLayoutMetrics.clampWidth(900, windowWidth: 1000), 500)
    }
}
