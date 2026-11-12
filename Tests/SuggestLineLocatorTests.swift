import XCTest
@testable import seahelm

final class SuggestLineLocatorTests: XCTestCase {
    private typealias Span = SuggestLinePlacement.Span

    func testOptionsAreFoundInCellsOnTheLowestMatchingLine() {
        let rows = [
            "  ::seahelm-suggest:: old | other",
            "",
            "  我建议先做原型。",
            "  ::seahelm-suggest:: 做原型 | Ship it",
            "",
        ]
        let p = SuggestLineLocator.locate(options: ["做原型", "Ship it"], in: rows)
        XCTAssertEqual(p?.marker, Span(row: 3, column: 2, width: 19))
        // Wide characters take two cells each.
        XCTAssertEqual(p?.options, [Span(row: 3, column: 22, width: 6), Span(row: 3, column: 31, width: 7)])
    }

    func testAWrappedLineIsFollowedOntoTheRowsBelow() {
        let rows = ["⏺ ::seahelm-suggest:: merge it |", "  run the tests"]
        let p = SuggestLineLocator.locate(options: ["merge it", "run the tests"], in: rows)
        XCTAssertEqual(p?.options, [Span(row: 0, column: 22, width: 8), Span(row: 1, column: 2, width: 13)])
    }

    func testALineThatDoesNotSayExactlyWhatTheCardSaysGetsNothing() {
        let card = ["a", "b"]
        for rows in [
            ["::seahelm-suggest:: a | b | c"],       // more options than the card
            ["::seahelm-suggest:: b | a"],           // another order
            ["::seahelm-suggest:: a b"],             // no separator
            ["::seahelm-suggest:: x a | b"],         // text before the first
            ["::seahelm-suggest:: a || b"],          // an empty option between
            ["no marker a | b"],
        ] {
            XCTAssertNil(SuggestLineLocator.locate(options: card, in: rows), "\(rows)")
        }
        // An option cut where it wraps.
        XCTAssertNil(SuggestLineLocator.locate(options: ["merge it"], in: ["::seahelm-suggest:: mer", "ge it"]))
    }
}
