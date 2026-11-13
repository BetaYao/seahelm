import XCTest
@testable import seahelm

/// Answering the same suggestion twice while the first call is in flight would
/// type the option into Cursor Agent again as a follow-up left in the composer.
final class CardDeckAnswerTests: XCTestCase {
    func testIgnoresSecondAnswerWhileFirstIsInFlight() {
        let deck = CardDeck()
        let card = Card(id: "c-1", kind: .suggestion, options: ["run tests", "skip"])
        var calls = 0
        var finishFirst: (() -> Void)?
        deck.answerImpl = { _, _, done in
            calls += 1
            finishFirst = done
        }

        deck.answer(card, label: "run tests")
        deck.answer(card, label: "run tests")
        XCTAssertEqual(calls, 1, "second tap must not reach the core while the first answer runs")

        finishFirst?()
        deck.answer(card, label: "skip")
        XCTAssertEqual(calls, 2, "a new answer is allowed after the first finishes")
    }
}
