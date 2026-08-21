import XCTest
@testable import seahelm

final class SuggestionSeenSetTests: XCTestCase {
    private func order(message: String, options: [String], terminalID: String = "t1",
                       wt: String = "/wt/x") -> PendingOrder {
        let action = FirstMateAction(kind: .suggestNextOrder, zone: .red, worktreePath: wt,
                                     branch: "b", project: "p", terminalID: terminalID,
                                     message: message, options: options)
        return PendingOrder(id: PendingOrdersQueue.key(action), action: action)
    }

    func testFirstSightIsFresh() {
        var seen = SuggestionSeenSet()
        XCTAssertEqual(seen.absorb([order(message: "shipped", options: ["test", "commit"])]).count, 1)
    }

    func testUnchangedCardIsNotFreshAgain() {
        var seen = SuggestionSeenSet()
        let card = order(message: "shipped", options: ["test", "commit"])
        _ = seen.absorb([card])
        XCTAssertTrue(seen.absorb([card]).isEmpty, "the 10s fallback refresh must not re-pop a card")
    }

    /// The regression this type exists for: card ids are stable per pane, so the
    /// second suggestion from one pane reuses the id an id-set comparison keys on.
    func testSecondSuggestionForSamePaneIsFresh() {
        var seen = SuggestionSeenSet()
        let first = order(message: "shipped", options: ["test", "commit"])
        let second = order(message: "tests pass", options: ["push", "open PR"])
        _ = seen.absorb([first])
        XCTAssertEqual(second.id, first.id, "precondition: ids collide per pane")
        XCTAssertEqual(seen.absorb([second]).count, 1)
    }

    func testRewrittenSummaryWithSameOptionsIsFresh() {
        var seen = SuggestionSeenSet()
        _ = seen.absorb([order(message: "shipped", options: ["test", "commit"])])
        let reAsked = order(message: "reverted the migration", options: ["test", "commit"])
        XCTAssertEqual(seen.absorb([reAsked]).count, 1)
    }

    /// `PendingOrdersQueue.refreshSuggestMessage` upgrades a junk summary to the
    /// agent's real prose without touching the options — same ask, better text.
    func testJunkSummaryUpgradeIsNotFresh() {
        var seen = SuggestionSeenSet()
        _ = seen.absorb([order(message: "Shell", options: ["test", "commit"])])
        let upgraded = order(message: "Removed the dead migration path", options: ["test", "commit"])
        XCTAssertTrue(seen.absorb([upgraded]).isEmpty)
    }

    func testResolvedCardIsFreshWhenRaisedAgain() {
        var seen = SuggestionSeenSet()
        let card = order(message: "shipped", options: ["test", "commit"])
        _ = seen.absorb([card])
        _ = seen.absorb([])
        XCTAssertEqual(seen.absorb([card]).count, 1)
    }

    func testFreshEntriesAreReturnedNotJustCounted() {
        var seen = SuggestionSeenSet()
        let known = order(message: "shipped", options: ["test"], terminalID: "t1", wt: "/wt/a")
        _ = seen.absorb([known])
        let other = order(message: "needs review", options: ["review"], terminalID: "t2", wt: "/wt/b")
        let fresh = seen.absorb([known, other])
        XCTAssertEqual(fresh.map(\.action.worktreePath), ["/wt/b"],
                       "callers route by which worktree the new card belongs to")
    }
}
