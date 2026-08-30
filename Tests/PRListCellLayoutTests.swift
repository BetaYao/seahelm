import XCTest
@testable import seahelm

/// The PR row's proportions.
///
/// The row is a one-letter state badge, then the title, with the author under
/// it. The badge had a lower width bound and no upper one, its label did not
/// hug its text, and the title's compression resistance was `.defaultLow` — so
/// the solver had a cheaper way to satisfy the constraints than keeping the
/// title readable, and gave almost the entire row to the badge.
final class PRListCellLayoutTests: XCTestCase {

    private func laidOutCell(width: CGFloat = 900) throws -> PRTableCellView {
        let cell = PRTableCellView(frame: NSRect(x: 0, y: 0, width: width, height: 52))
        cell.configure(with: try firstListPR())
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    func testBadgeStaysABadge() throws {
        let cell = try laidOutCell()
        XCTAssertLessThanOrEqual(cell.badgeFrameForTesting.width, 28,
                                 "a one-letter badge took \(cell.badgeFrameForTesting.width)pt")
    }

    /// The inverse, stated in terms of the row rather than the badge: whatever
    /// the badge does, the title is what the row is for.
    func testTitleGetsTheRow() throws {
        let cell = try laidOutCell(width: 900)
        let title = cell.titleFrameForTesting
        XCTAssertGreaterThan(title.width, 700, "title got only \(title.width)pt of 900")
        XCTAssertLessThan(title.minX, 60, "title starts at \(title.minX)pt — pushed right by something")
    }

    func testProportionsHoldInANarrowColumn() throws {
        let cell = try laidOutCell(width: 320)
        XCTAssertLessThanOrEqual(cell.badgeFrameForTesting.width, 28)
        XCTAssertGreaterThan(cell.titleFrameForTesting.width, 200)
    }

    /// The list endpoint has no line counts, so the meta line is the author
    /// alone — not a `+0 -0` that would read as an empty PR.
    func testMetaShowsTheAuthorWithoutInventedCounts() throws {
        let cell = try laidOutCell()
        let pr = try firstListPR()
        XCTAssertEqual(cell.metaTextForTesting, pr.user.login)
        XCTAssertFalse(cell.metaTextForTesting.contains("+0"))
    }

    func testTitleCarriesTheNumber() throws {
        let cell = try laidOutCell()
        let pr = try firstListPR()
        XCTAssertTrue(cell.titleTextForTesting.hasPrefix("#\(pr.number) "), cell.titleTextForTesting)
    }

    private func firstListPR() throws -> GitHubPR {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "github-pr-list", withExtension: "json"))
        let prs = try JSONDecoder().decode([GitHubPR].self, from: Data(contentsOf: url))
        return try XCTUnwrap(prs.first)
    }
}
