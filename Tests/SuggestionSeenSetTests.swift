import XCTest
@testable import seahelm

final class SuggestionSeenSetTests: XCTestCase {
    private func card(_ id: String = "c1", message: String, options: [String], kind: Card.Kind = .suggestion,
                      wt: String = "/wt/x") -> Card {
        Card(id: id, kind: kind, terminalID: "t1", worktreePath: wt, message: message, options: options)
    }

    func testFirstSightIsFresh() {
        var seen = SuggestionSeenSet()
        XCTAssertEqual(seen.absorb([card(message: "shipped", options: ["test", "commit"])]).count, 1)
    }

    func testUnchangedCardIsNotFreshAgain() {
        var seen = SuggestionSeenSet()
        let c = card(message: "shipped", options: ["test", "commit"])
        _ = seen.absorb([c])
        XCTAssertTrue(seen.absorb([c]).isEmpty, "the fallback refresh must not re-pop a card")
    }

    /// A pane's next suggestion reuses its card's id; what it shows is new.
    func testNextSuggestionUnderTheSameIdIsFresh() {
        var seen = SuggestionSeenSet()
        _ = seen.absorb([card(message: "shipped", options: ["test", "commit"])])
        XCTAssertEqual(seen.absorb([card(message: "tests pass", options: ["push", "open PR"])]).count, 1)
    }

    func testBrieflyVanishedCardDoesNotReopen() {
        var seen = SuggestionSeenSet()
        let c = card(message: "shipped", options: ["test", "commit"])
        let now = Date()
        _ = seen.absorb([c], now: now)
        _ = seen.absorb([], now: now.addingTimeInterval(1))
        XCTAssertTrue(seen.absorb([c], now: now.addingTimeInterval(2)).isEmpty)
    }

    /// A question asked again is a new ask, even in the same words.
    func testReAskedQuestionIsShownAgain() {
        var seen = SuggestionSeenSet()
        let q = card(message: "Pick fruits", options: ["Apple", "Banana"], kind: .question)
        let now = Date()
        _ = seen.absorb([q], now: now)
        _ = seen.absorb([], now: now.addingTimeInterval(5))
        XCTAssertEqual(seen.absorb([q], now: now.addingTimeInterval(60)).count, 1)
    }

    func testLongGoneCardCanBeRaisedAgain() {
        var seen = SuggestionSeenSet()
        let c = card(message: "shipped", options: ["test", "commit"])
        let now = Date()
        _ = seen.absorb([c], now: now)
        _ = seen.absorb([], now: now.addingTimeInterval(1))
        XCTAssertEqual(seen.absorb([c], now: now.addingTimeInterval(SuggestionSeenSet.reappearanceGrace + 2)).count, 1)
    }

    func testFreshCardsAreReturned() {
        var seen = SuggestionSeenSet()
        let known = card("a", message: "shipped", options: ["test"], wt: "/wt/a")
        _ = seen.absorb([known])
        let other = card("b", message: "needs review", options: ["review"], wt: "/wt/b")
        XCTAssertEqual(seen.absorb([known, other]).map(\.worktreePath), ["/wt/b"])
    }

    func testCardReadsTheCoresJSON() {
        let c = Card(json: ["id": "c9", "kind": "question", "pane_session_key": "s", "worktree_path": "/wt",
                            "message": "which?", "options": ["a", "b"], "labels": ["☑ a", "☐ b", "✔ Done"],
                            "multi_select": true, "checked": [0], "created_at": 5.0],
                     terminalID: { key, _ in key == "s" ? "t1" : nil })
        XCTAssertEqual(c?.terminalID, "t1")
        XCTAssertEqual(c?.labels.last, Card.doneLabel)
        XCTAssertEqual(c?.checked, [0])
        XCTAssertTrue(c?.isAgentQuestion == true)
        XCTAssertNil(Card(json: ["id": "x", "kind": "nonsense"], terminalID: { _, _ in nil }))
    }
}
