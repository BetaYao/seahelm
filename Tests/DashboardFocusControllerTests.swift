import XCTest
@testable import seahelm

final class DashboardFocusControllerTests: XCTestCase {

    // MARK: - Focus-layout ring

    func testFocusLayoutRingStartsAtBigPanel() {
        let ctrl = DashboardFocusController()
        ctrl.enterFocusLayout(cardIds: ["a", "b"])
        XCTAssertEqual(ctrl.focusedTarget, .bigPanel)
    }

    func testFocusLayoutStartsAtSelectedCard() {
        let ctrl = DashboardFocusController()
        ctrl.enterFocusLayout(cardIds: ["a", "b"], initialId: "b")
        XCTAssertEqual(ctrl.focusedTarget, .card("b"))
    }

    func testFocusLayoutUnknownInitialFallsBackToBigPanel() {
        let ctrl = DashboardFocusController()
        ctrl.enterFocusLayout(cardIds: ["a", "b"], initialId: "z")
        XCTAssertEqual(ctrl.focusedTarget, .bigPanel)
    }

    func testFocusLayoutRingCyclesPanelThenCards() {
        let ctrl = DashboardFocusController()
        ctrl.enterFocusLayout(cardIds: ["a", "b"])
        ctrl.next() // first card
        XCTAssertEqual(ctrl.focusedTarget, .card("a"))
        ctrl.next()
        XCTAssertEqual(ctrl.focusedTarget, .card("b"))
        ctrl.next() // back to big panel
        XCTAssertEqual(ctrl.focusedTarget, .bigPanel)
    }

    func testFocusLayoutPrevFromBigPanelGoesToLastCard() {
        let ctrl = DashboardFocusController()
        ctrl.enterFocusLayout(cardIds: ["a", "b"])
        ctrl.prev()
        XCTAssertEqual(ctrl.focusedTarget, .card("b"))
    }

    // MARK: - Delete shifts focus

    func testDeleteShiftsFocusToNextCard() {
        let ctrl = DashboardFocusController()
        ctrl.enterFocusLayout(cardIds: ["a", "b", "c"], initialId: "b")
        ctrl.removeCurrentCard()
        // After removing "b", ring is ["a", "c"] and focus advances to "c"
        XCTAssertEqual(ctrl.focusedTarget, .card("c"))
    }

    func testDeleteLastCardWrapsToFirst() {
        let ctrl = DashboardFocusController()
        ctrl.enterFocusLayout(cardIds: ["a", "b", "c"], initialId: "c")
        ctrl.removeCurrentCard()
        XCTAssertEqual(ctrl.focusedTarget, .card("a"))
    }

    func testDeleteInFocusLayoutFallsBackToBigPanelIfNoCardsLeft() {
        let ctrl = DashboardFocusController()
        ctrl.enterFocusLayout(cardIds: ["a"])
        ctrl.next() // focus card "a"
        ctrl.removeCurrentCard()
        XCTAssertEqual(ctrl.focusedTarget, .bigPanel)
    }
}
