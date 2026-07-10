import XCTest
@testable import seahelm

final class ReturnToPortTests: XCTestCase {
    func testNoWarnings() {
        let p = PortPrecheck(hasUnmergedCommits: false, hasUnpushedCommits: false, hasUncommittedChanges: false)
        XCTAssertFalse(p.hasWarnings)
        XCTAssertEqual(ReturnToPort.warningSummary(p), "No risk, safe to dock")
    }

    func testUnpushedWarning() {
        let p = PortPrecheck(hasUnmergedCommits: false, hasUnpushedCommits: true, hasUncommittedChanges: false)
        XCTAssertTrue(p.hasWarnings)
        XCTAssertTrue(ReturnToPort.warningSummary(p).contains("unpushed"))
    }

    func testMultipleWarnings() {
        let p = PortPrecheck(hasUnmergedCommits: true, hasUnpushedCommits: true, hasUncommittedChanges: true)
        let s = ReturnToPort.warningSummary(p)
        XCTAssertTrue(s.contains("unmerged"))
        XCTAssertTrue(s.contains("unpushed"))
        XCTAssertTrue(s.contains("uncommitted"))
    }
}
