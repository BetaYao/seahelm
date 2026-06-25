import XCTest

/// Base test class for all seahelm UI tests.
/// Handles app launch/teardown and screenshot capture on failure.
class SeahelmUITestCase: XCTestCase {
    var page: AppPage!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        page = AppPage().launch()
    }

    override func tearDown() {
        if testRun?.failureCount ?? 0 > 0 {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        page.terminate()
        super.tearDown()
    }
}
