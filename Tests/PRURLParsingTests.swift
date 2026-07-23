import XCTest
@testable import seahelm

/// Covers `GhosttyNSView.parsePRURL` — the pure URL parser behind the pane
/// context menu's "Preview PR" item.
final class PRURLParsingTests: XCTestCase {

    // MARK: - Valid URLs

    func testStandardHTTPS() {
        let result = GhosttyNSView.parsePRURL("https://github.com/apple/swift/pull/12345")
        XCTAssertEqual(result?.owner, "apple")
        XCTAssertEqual(result?.repo, "swift")
        XCTAssertEqual(result?.number, 12345)
    }

    func testHTTP() {
        let result = GhosttyNSView.parsePRURL("http://github.com/owner/repo/pull/42")
        XCTAssertEqual(result?.owner, "owner")
        XCTAssertEqual(result?.repo, "repo")
        XCTAssertEqual(result?.number, 42)
    }

    func testWithoutProtocol() {
        let result = GhosttyNSView.parsePRURL("github.com/owner/repo/pull/1")
        XCTAssertEqual(result?.owner, "owner")
        XCTAssertEqual(result?.repo, "repo")
        XCTAssertEqual(result?.number, 1)
    }

    func testTrailingSlash() {
        let result = GhosttyNSView.parsePRURL("https://github.com/owner/repo/pull/99/")
        XCTAssertEqual(result?.owner, "owner")
        XCTAssertEqual(result?.repo, "repo")
        XCTAssertEqual(result?.number, 99)
    }

    func testDashesInOwnerAndRepo() {
        let result = GhosttyNSView.parsePRURL("https://github.com/my-org/my-repo/pull/7")
        XCTAssertEqual(result?.owner, "my-org")
        XCTAssertEqual(result?.repo, "my-repo")
        XCTAssertEqual(result?.number, 7)
    }

    func testDotsInRepo() {
        let result = GhosttyNSView.parsePRURL("https://github.com/org/repo.name/pull/100")
        XCTAssertEqual(result?.owner, "org")
        XCTAssertEqual(result?.repo, "repo.name")
        XCTAssertEqual(result?.number, 100)
    }

    func testUnderscores() {
        let result = GhosttyNSView.parsePRURL("https://github.com/test_user/my_repo/pull/256")
        XCTAssertEqual(result?.owner, "test_user")
        XCTAssertEqual(result?.repo, "my_repo")
        XCTAssertEqual(result?.number, 256)
    }

    func testMarkdownLinkSyntax() {
        let result = GhosttyNSView.parsePRURL("[https://github.com/owner/repo/pull/5](...)")
        XCTAssertEqual(result?.owner, "owner")
        XCTAssertEqual(result?.repo, "repo")
        XCTAssertEqual(result?.number, 5)
    }

    func testTrailingPunctuation() {
        let result = GhosttyNSView.parsePRURL("https://github.com/owner/repo/pull/123,")
        XCTAssertEqual(result?.owner, "owner")
        XCTAssertEqual(result?.repo, "repo")
        XCTAssertEqual(result?.number, 123)
    }

    func testAngleBrackets() {
        let result = GhosttyNSView.parsePRURL("<https://github.com/owner/repo/pull/456>")
        XCTAssertEqual(result?.owner, "owner")
        XCTAssertEqual(result?.repo, "repo")
        XCTAssertEqual(result?.number, 456)
    }

    func testParentheses() {
        let result = GhosttyNSView.parsePRURL("(https://github.com/owner/repo/pull/789)")
        XCTAssertEqual(result?.owner, "owner")
        XCTAssertEqual(result?.repo, "repo")
        XCTAssertEqual(result?.number, 789)
    }

    // MARK: - Invalid inputs

    func testNotAPR() {
        XCTAssertNil(GhosttyNSView.parsePRURL("https://github.com/owner/repo"))
    }

    func testNotAGitHubURL() {
        XCTAssertNil(GhosttyNSView.parsePRURL("https://gitlab.com/owner/repo/pull/1"))
    }

    func testNonNumericPRNumber() {
        XCTAssertNil(GhosttyNSView.parsePRURL("https://github.com/owner/repo/pull/abc"))
    }

    func testEmptyString() {
        XCTAssertNil(GhosttyNSView.parsePRURL(""))
    }

    func testWhitespaceOnly() {
        XCTAssertNil(GhosttyNSView.parsePRURL("   "))
    }

    func testNegativeNumber() {
        // PR 编号不可能是负数，但确保不会 crash
        XCTAssertNil(GhosttyNSView.parsePRURL("https://github.com/owner/repo/pull/-1"))
    }

    func testZeroNumber() {
        XCTAssertNil(GhosttyNSView.parsePRURL("https://github.com/owner/repo/pull/0"))
    }

    func testTreeInsteadOfPull() {
        XCTAssertNil(GhosttyNSView.parsePRURL("https://github.com/owner/repo/tree/main"))
    }

    func testIssuesNotPRs() {
        XCTAssertNil(GhosttyNSView.parsePRURL("https://github.com/owner/repo/issues/42"))
    }

    func testSubdomain() {
        XCTAssertNil(GhosttyNSView.parsePRURL("https://custom.github.com/owner/repo/pull/1"))
    }
}
