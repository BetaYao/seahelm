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

    func testCardHeightGrowsWithMoreButtons() {
        let small = BridgePanelViewController.cardHeight(for: order(kind: .returnToPort, options: nil))
        let big = BridgePanelViewController.cardHeight(for: order(kind: .suggestNextOrder,
                                                                  options: ["a", "b", "c", "d", "e"]))
        XCTAssertGreaterThan(big, small)
    }
}
