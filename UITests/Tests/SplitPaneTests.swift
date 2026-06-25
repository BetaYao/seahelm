import XCTest

class SplitPaneTests: SeahelmUITestCase {

    func testHorizontalSplit() {
        guard page.repo.terminal.waitForExistence(timeout: 10) else {
            XCTFail("Terminal not visible — need a configured workspace for this test")
            return
        }

        XCTAssertEqual(page.splitPane.paneCount, 1)
        XCTAssertEqual(page.splitPane.dividerCount, 0)

        page.app.typeKey("d", modifierFlags: .command)

        let secondPane = page.splitPane.panes.element(boundBy: 1)
        XCTAssertTrue(secondPane.waitForExistence(timeout: 5), "Second pane should appear after Cmd+D")
        XCTAssertEqual(page.splitPane.paneCount, 2)
        XCTAssertEqual(page.splitPane.dividerCount, 1)
    }

    func testVerticalSplit() {
        guard page.repo.terminal.waitForExistence(timeout: 10) else {
            XCTFail("Terminal not visible")
            return
        }

        page.app.typeKey("d", modifierFlags: [.command, .shift])

        let secondPane = page.splitPane.panes.element(boundBy: 1)
        XCTAssertTrue(secondPane.waitForExistence(timeout: 5), "Second pane should appear after Cmd+Shift+D")
        XCTAssertEqual(page.splitPane.paneCount, 2)
    }

    func testClosePane() {
        guard page.repo.terminal.waitForExistence(timeout: 10) else {
            XCTFail("Terminal not visible")
            return
        }

        page.app.typeKey("d", modifierFlags: .command)
        let secondPane = page.splitPane.panes.element(boundBy: 1)
        XCTAssertTrue(secondPane.waitForExistence(timeout: 5))

        page.app.typeKey("w", modifierFlags: [.command, .shift])

        XCTAssertTrue(secondPane.waitForNonExistence(timeout: 5), "Second pane should disappear after Cmd+Shift+W")
        XCTAssertEqual(page.splitPane.paneCount, 1)
        XCTAssertEqual(page.splitPane.dividerCount, 0)
    }

    func testCannotCloseLastPane() {
        guard page.repo.terminal.waitForExistence(timeout: 10) else {
            XCTFail("Terminal not visible")
            return
        }

        XCTAssertEqual(page.splitPane.paneCount, 1)
        page.app.typeKey("w", modifierFlags: [.command, .shift])
        XCTAssertEqual(page.splitPane.paneCount, 1)
    }

    func testRecursiveSplit() {
        guard page.repo.terminal.waitForExistence(timeout: 10) else {
            XCTFail("Terminal not visible")
            return
        }

        page.app.typeKey("d", modifierFlags: .command)
        let secondPane = page.splitPane.panes.element(boundBy: 1)
        XCTAssertTrue(secondPane.waitForExistence(timeout: 5))

        page.app.typeKey("d", modifierFlags: [.command, .shift])
        let thirdPane = page.splitPane.panes.element(boundBy: 2)
        XCTAssertTrue(thirdPane.waitForExistence(timeout: 5))

        XCTAssertEqual(page.splitPane.paneCount, 3)
        XCTAssertEqual(page.splitPane.dividerCount, 2)
    }
}
