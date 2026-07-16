import XCTest
@testable import seahelm

final class BridgeCardModelTests: XCTestCase {
    private func order(kind: FirstMateActionKind, options: [String]?) -> PendingOrder {
        let a = FirstMateAction(kind: kind, zone: .red, worktreePath: "/wt", branch: "b",
                                project: "p", terminalID: "t", message: "m", options: options)
        return PendingOrder(id: "id", action: a)
    }

    func testSuggestionButtonsAreItsOptions() {
        let o = order(kind: .suggestNextOrder, options: ["run tests", "open PR"])
        XCTAssertEqual(BridgePanelViewController.buttonTitles(for: o), ["run tests", "open PR"])
    }

    func testSingleActionButtonIsApprove() {
        let o = order(kind: .returnToPort, options: nil)
        XCTAssertEqual(BridgePanelViewController.buttonTitles(for: o), ["Approve"])
    }

    /// Lays out a real card: catches an invalid stack alignment (which asserts at
    /// runtime, not compile time) and proves the chips stack instead of sharing one
    /// row — each must get the card's full width so its label can actually be read.
    func testOptionChipsStackVerticallyAtFullWidth() {
        let o = order(kind: .suggestNextOrder, options: ["查 compose 缺失的服务", "run the tests", "open a PR"])
        let card = OrderCardView()
        card.configure(order: o) { _ in }
        card.frame = NSRect(x: 0, y: 0, width: 320, height: BridgePanelViewController.cardHeight(for: o))
        card.layoutSubtreeIfNeeded()

        let chips = card.optionChipFrames
        XCTAssertEqual(chips.count, 3)

        // Stacked: each chip strictly below the previous, none sharing a row.
        for (a, b) in zip(chips, chips.dropFirst()) {
            XCTAssertNotEqual(a.minY, b.minY, "chips still share a row — labels get truncated away")
        }
        // Full width: a chip squeezed to its number badge is ~30pt wide.
        for chip in chips {
            XCTAssertGreaterThan(chip.width, 200, "chip too narrow to show its label")
        }
    }

    func testCardHeightGrowsWithMoreButtons() {
        let small = BridgePanelViewController.cardHeight(for: order(kind: .returnToPort, options: nil))
        let big = BridgePanelViewController.cardHeight(for: order(kind: .suggestNextOrder,
                                                                  options: ["a", "b", "c", "d", "e"]))
        XCTAssertGreaterThan(big, small)
    }
}
