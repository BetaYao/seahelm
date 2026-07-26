import XCTest
@testable import seahelm

final class KeyboardSubstateControllerTests: XCTestCase {

    func testStartsIdle() {
        let c = KeyboardSubstateController()
        XCTAssertEqual(c.substate, .none)
        XCTAssertTrue(c.isIdle)
    }

    // MARK: - Delete confirmation

    func testConfirmReturnsThePendingAgentAndClears() {
        let c = KeyboardSubstateController()
        c.beginDelete(agentId: "a1")
        XCTAssertEqual(c.substate, .deletePending(agentId: "a1"))
        XCTAssertFalse(c.isIdle)
        XCTAssertEqual(c.confirmDelete(), "a1")
        XCTAssertTrue(c.isIdle)
    }

    /// Confirming twice must not delete a second time — the classic double-`d` bug.
    func testConfirmIsNotIdempotentlyDestructive() {
        let c = KeyboardSubstateController()
        c.beginDelete(agentId: "a1")
        XCTAssertEqual(c.confirmDelete(), "a1")
        XCTAssertNil(c.confirmDelete())
    }

    func testCancelClearsWithoutReturningAnAgent() {
        let c = KeyboardSubstateController()
        c.beginDelete(agentId: "a1")
        c.cancelDelete()
        XCTAssertTrue(c.isIdle)
        XCTAssertNil(c.confirmDelete())
    }

    /// cancelDelete is called on every nav-ring exit, so it must be a no-op when
    /// some *other* substate is live — it must not clobber an open create form.
    func testCancelDeleteLeavesCreateFormAlone() {
        let c = KeyboardSubstateController()
        c.beginCreateForm()
        c.cancelDelete()
        XCTAssertEqual(c.substate, .createForm)
    }

    // MARK: - Create form

    func testCreateFormBeginAndEnd() {
        let c = KeyboardSubstateController()
        c.beginCreateForm()
        XCTAssertEqual(c.substate, .createForm)
        c.endCreateForm()
        XCTAssertTrue(c.isIdle)
    }

    func testEndCreateFormIgnoresAPendingDelete() {
        let c = KeyboardSubstateController()
        c.beginDelete(agentId: "a1")
        c.endCreateForm()
        XCTAssertEqual(c.substate, .deletePending(agentId: "a1"))
    }

    func testResetClearsAnything() {
        let c = KeyboardSubstateController()
        c.beginDelete(agentId: "a1")
        c.reset()
        XCTAssertTrue(c.isIdle)
    }
}
