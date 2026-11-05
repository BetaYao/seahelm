import XCTest
@testable import seahelm

/// AskUserQuestion's header and option descriptions, as the island reads them
/// from the core's card JSON.
final class CardDetailsTests: XCTestCase {
    private func card(_ extra: [String: Any]) -> Card? {
        var d: [String: Any] = ["id": "c-1", "kind": "question", "message": "Which customer?",
                                "options": ["Banana", "None"], "labels": ["Banana", "None"]]
        extra.forEach { d[$0.key] = $0.value }
        return Card(json: d) { _, _ in nil }
    }

    func testReadsHeaderAndDetails() throws {
        let c = try XCTUnwrap(card(["header": " Customer ", "details": ["closing the books", ""]]))
        XCTAssertEqual(c.header, "Customer")
        XCTAssertEqual(c.detail(forLabelAt: 0), "closing the books")
        XCTAssertEqual(c.detail(forLabelAt: 1), "")
    }

    func testCardWithoutThemHasNone() throws {
        let c = try XCTUnwrap(card([:]))
        XCTAssertEqual(c.header, "")
        XCTAssertEqual(c.detail(forLabelAt: 0), "")
    }

    /// A multi-select's labels are the ticked options and then Done: each
    /// option keeps its description, Done gets none.
    func testMultiSelectDoneHasNoDetail() throws {
        let c = try XCTUnwrap(card(["multi_select": true, "labels": ["☐ Banana", "☐ None", "✔ Done"],
                                    "details": ["closing the books", "internal"]]))
        XCTAssertEqual(c.detail(forLabelAt: 1), "internal")
        XCTAssertEqual(c.detail(forLabelAt: 2), "")
    }

    func testDetailsThatDoNotLineUpAreIgnored() throws {
        let c = try XCTUnwrap(card(["details": ["only one"]]))
        XCTAssertEqual(c.detail(forLabelAt: 0), "")
    }
}
