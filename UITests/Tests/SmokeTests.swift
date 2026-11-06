import XCTest

class SmokeTests: SeahelmUITestCase {
    func testSettingsStaysInMainWindowAndReopensAfterClose() {
        let app = page.app
        XCTAssertTrue(page.chrome.themeButton.waitForExistence(timeout: 15))
        let windowCount = app.windows.count
        page.settings.open()
        XCTAssertTrue(page.settings.sheet.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, windowCount)
        let sidebar = app.buttons["settings.sidebar.agents"]
        XCTAssertTrue(sidebar.isHittable)
        sidebar.click()
        page.settings.open()
        XCTAssertEqual(app.windows.count, windowCount)
        app.buttons["centerOverlay.closeButton"].click()
        XCTAssertTrue(page.settings.sheet.waitForNonExistence(timeout: 5))
        page.settings.open()
        XCTAssertTrue(page.settings.workspacePaths.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, windowCount)
    }

    func testPairMenuOpensSettingsPairingWithoutAnotherWindow() {
        let app = page.app
        XCTAssertTrue(page.chrome.themeButton.waitForExistence(timeout: 15))
        let windowCount = app.windows.count
        app.menuBars.menuBarItems["Seahelm"].click()
        app.menuItems["Pair Remote Clients..."].click()
        XCTAssertTrue(page.settings.sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Web access"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, windowCount)
        app.buttons["settings.sidebar.general"].click()
        XCTAssertTrue(page.settings.workspacePaths.waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Seahelm"].click()
        app.menuItems["Pair Remote Clients..."].click()
        XCTAssertTrue(app.staticTexts["Web access"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, windowCount)
    }
}
