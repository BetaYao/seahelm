import XCTest
@testable import seahelm

final class KeyboardModeControllerTests: XCTestCase {
    func testStartsInNormal() {
        let c = KeyboardModeController()
        XCTAssertEqual(c.mode, .normal)
        XCTAssertEqual(c.substate, .none)
    }

    func testEnterInsertSetsMode() {
        let c = KeyboardModeController()
        c.enterInsert()
        XCTAssertEqual(c.mode, .insert)
    }

    func testEnterNormalFromInsert() {
        let c = KeyboardModeController()
        c.enterInsert()
        c.enterNormal()
        XCTAssertEqual(c.mode, .normal)
    }

    func testModeChangeNotifiesDelegate() {
        let c = KeyboardModeController()
        let spy = ModeSpy()
        c.delegate = spy
        c.enterInsert()
        XCTAssertEqual(spy.modeChangeCount, 1)
        XCTAssertEqual(spy.lastMode, .insert)
    }
}

extension KeyboardModeControllerTests {
    func testCmdEscFromInsertGoesNormal() {
        let c = KeyboardModeController()
        c.enterInsert()
        let handled = c.handleEsc(hasCommand: true, now: 0)
        XCTAssertTrue(handled)
        XCTAssertEqual(c.mode, .normal)
    }

    func testSingleEscInInsertDoesNotExit() {
        let c = KeyboardModeController()
        c.enterInsert()
        let handled = c.handleEsc(hasCommand: false, now: 0)
        XCTAssertFalse(handled)          // passes through to terminal
        XCTAssertEqual(c.mode, .insert)
    }

    func testRepeatedPlainEscNeverExits() {
        let c = KeyboardModeController()
        c.enterInsert()
        // Double-Esc is gone: any number of plain escs always pass through.
        XCTAssertFalse(c.handleEsc(hasCommand: false, now: 0.0))
        XCTAssertFalse(c.handleEsc(hasCommand: false, now: 0.10))
        XCTAssertFalse(c.handleEsc(hasCommand: false, now: 0.20))
        XCTAssertEqual(c.mode, .insert)
    }
}

extension KeyboardModeControllerTests {
    func testBeginDeleteEntersPending() {
        let c = KeyboardModeController()
        c.beginDelete(agentId: "a1")
        XCTAssertEqual(c.substate, .deletePending(agentId: "a1"))
    }

    func testConfirmDeleteReturnsAgentAndClears() {
        let c = KeyboardModeController()
        c.beginDelete(agentId: "a1")
        let confirmed = c.confirmDelete()
        XCTAssertEqual(confirmed, "a1")
        XCTAssertEqual(c.substate, .none)
    }

    func testConfirmDeleteWithoutPendingReturnsNil() {
        let c = KeyboardModeController()
        XCTAssertNil(c.confirmDelete())
    }

    func testCancelDeleteClearsPending() {
        let c = KeyboardModeController()
        c.beginDelete(agentId: "a1")
        c.cancelDelete()
        XCTAssertEqual(c.substate, .none)
    }
}

extension KeyboardModeControllerTests {
    func testHintNormal() {
        let c = KeyboardModeController()
        XCTAssertTrue(c.hintText.contains("hjkl"))
        XCTAssertTrue(c.hintText.contains("⏎"))
    }

    func testHintInsert() {
        let c = KeyboardModeController()
        c.enterInsert()
        XCTAssertTrue(c.hintText.contains("⌘esc"))
    }

    func testHintDeletePending() {
        let c = KeyboardModeController()
        c.beginDelete(agentId: "a1")
        XCTAssertTrue(c.hintText.uppercased().contains("DELETE?"))
    }

    func testHintCreateForm() {
        let c = KeyboardModeController()
        c.beginCreateForm()
        XCTAssertEqual(c.substate, .createForm)
        XCTAssertTrue(c.hintText.contains("tab"))
    }

    func testEndCreateFormReturnsNormal() {
        let c = KeyboardModeController()
        c.beginCreateForm()
        c.endCreateForm()
        XCTAssertEqual(c.substate, .none)
    }
}

final class ModeSpy: KeyboardModeDelegate {
    var modeChangeCount = 0
    var lastMode: KeyboardMode?
    var lastHint: String?
    func keyboardModeDidChange(_ mode: KeyboardMode, substate: KeyboardSubstate) {
        modeChangeCount += 1
        lastMode = mode
    }
    func keyboardHintDidChange(_ hint: String) { lastHint = hint }
}
