import XCTest
@testable import seahelm

final class ReturnToPortTests: XCTestCase {
    func testNoWarnings() {
        let p = PortPrecheck(hasUnmergedCommits: false, hasUnpushedCommits: false, hasUncommittedChanges: false)
        XCTAssertFalse(p.hasWarnings)
        XCTAssertEqual(ReturnToPort.warningSummary(p), "无风险,可安全入坞")
    }

    func testUnpushedWarning() {
        let p = PortPrecheck(hasUnmergedCommits: false, hasUnpushedCommits: true, hasUncommittedChanges: false)
        XCTAssertTrue(p.hasWarnings)
        XCTAssertTrue(ReturnToPort.warningSummary(p).contains("未 push"))
    }

    func testMultipleWarnings() {
        let p = PortPrecheck(hasUnmergedCommits: true, hasUnpushedCommits: true, hasUncommittedChanges: true)
        let s = ReturnToPort.warningSummary(p)
        XCTAssertTrue(s.contains("未 merge"))
        XCTAssertTrue(s.contains("未 push"))
        XCTAssertTrue(s.contains("未提交"))
    }
}
