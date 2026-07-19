import XCTest
@testable import seahelm

final class TerminalHeaderViewTests: XCTestCase {
    func testTerminalTitleFormat() {
        XCTAssertEqual(TerminalHeaderView.formatTitle(repo: "seahelm", pane: "main"), "seahelm · main")
    }

    func testTerminalTitleFormatOmitsEmptyPieces() {
        XCTAssertEqual(TerminalHeaderView.formatTitle(repo: "seahelm", pane: ""), "seahelm")
        XCTAssertEqual(TerminalHeaderView.formatTitle(repo: "", pane: "main"), "main")
        XCTAssertEqual(TerminalHeaderView.formatTitle(repo: "", pane: ""), "")
        XCTAssertEqual(TerminalHeaderView.formatTitle(repo: "  ", pane: " main "), "main")
    }
}
