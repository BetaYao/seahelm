import XCTest
@testable import seahelm

/// Decoding GitHub's two PR shapes.
///
/// The fixtures are unedited responses from the real API, on purpose. The bug
/// these guard against was a wrong assumption about which fields come back, and
/// a hand-written fixture would just restate that assumption in another file.
final class GitHubPRDecodingTests: XCTestCase {

    /// The list endpoint omits every per-PR count. Declaring them non-optional
    /// made this throw `keyNotFound`, so the PR list could never load — for any
    /// repo, ever, regardless of network or token.
    func testListResponseDecodes() throws {
        let prs = try JSONDecoder().decode([GitHubPR].self, from: fixture("github-pr-list"))
        let pr = try XCTUnwrap(prs.first)
        XCTAssertGreaterThan(pr.number, 0)
        XCTAssertFalse(pr.title.isEmpty)
        XCTAssertFalse(pr.user.login.isEmpty)
        XCTAssertFalse(pr.hasDetailCounts, "the list carries no counts")
        XCTAssertNil(pr.additions)
        XCTAssertNil(pr.changedFiles)
    }

    /// The single-PR endpoint does carry them, so the same type has to hold both.
    func testDetailResponseDecodesWithCounts() throws {
        let pr = try JSONDecoder().decode(GitHubPR.self, from: fixture("github-pr-detail"))
        XCTAssertTrue(pr.hasDetailCounts)
        XCTAssertNotNil(pr.additions)
        XCTAssertNotNil(pr.deletions)
        XCTAssertNotNil(pr.changedFiles)
        XCTAssertNotNil(pr.commits)
    }

    /// The fixtures are only worth anything if they still differ the way the API
    /// does — if GitHub starts returning counts in the list, this says so rather
    /// than silently making the other tests vacuous.
    func testFixturesStillDisagreeAboutCounts() throws {
        let list = try JSONSerialization.jsonObject(with: fixture("github-pr-list")) as? [[String: Any]]
        let detail = try JSONSerialization.jsonObject(with: fixture("github-pr-detail")) as? [String: Any]
        let row = try XCTUnwrap(list?.first)
        for key in ["additions", "deletions", "changed_files", "commits", "review_comments"] {
            XCTAssertNil(row[key], "list unexpectedly carries \(key)")
            XCTAssertNotNil(detail?[key], "detail unexpectedly lacks \(key)")
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
            "missing fixture \(name).json — is it in the test target's resources?"
        )
        return try Data(contentsOf: url)
    }
}
