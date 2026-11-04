import XCTest

/// The island says when seahelm-core is not answering, and only then.
/// Launches its own app per test (no `SeahelmUITestCase` launch), since the
/// one thing that differs is where the core's socket is.
final class CoreWarningUITests: XCTestCase {
    private var page: AppPage?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        page?.terminate()
        page = nil
        super.tearDown()
    }

    private func warning(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "island.warning").firstMatch
    }

    /// A socket nobody can listen on: `seahelm-core ensure` fails every time,
    /// so after the grace the island must say so.
    func testSilentCoreShowsTheCoreBadge() {
        let page = AppPage().launch(environment: ["SEAHELM_CORE_SOCKET": "/nonexistent/seahelm-ui/c.sock"])
        self.page = page
        let badge = warning(in: page.app)
        XCTAssertTrue(badge.waitForExistence(timeout: 30), "no island warning with the core unreachable")
        XCTAssertEqual(badge.label, "CORE")
    }

    /// The scratch core the app starts itself: no warning, ever.
    func testAnsweringCoreShowsNoWarning() {
        let page = AppPage().launch()
        self.page = page
        XCTAssertTrue(page.app.windows.firstMatch.waitForExistence(timeout: 15))
        // Past the launch grace and a few syncs.
        let quiet = expectation(description: "past the grace")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { quiet.fulfill() }
        wait(for: [quiet], timeout: 20)
        XCTAssertFalse(warning(in: page.app).exists, "island warns though the core answers")
    }
}
