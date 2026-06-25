import XCTest
@testable import seahelm

final class StatusBarModeTests: XCTestCase {
    func testUpdateModeShowsModeName() {
        let bar = StatusBarView(frame: .zero)
        bar.updateMode(.normal, hint: "NORMAL  ·  hjkl move")
        XCTAssertEqual(bar.modeTextForTesting, "NORMAL")
        XCTAssertTrue(bar.shortcutsTextForTesting.contains("hjkl"))
    }

    func testInsertModeText() {
        let bar = StatusBarView(frame: .zero)
        bar.updateMode(.insert, hint: "INSERT  ·  ⌘esc")
        XCTAssertEqual(bar.modeTextForTesting, "INSERT")
    }
}
