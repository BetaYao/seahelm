import XCTest
@testable import seahelm

final class KeyboardSubstateControllerTests: XCTestCase {

    func testStartsIdle() {
        let c = KeyboardSubstateController()
        XCTAssertEqual(c.substate, .none)
        XCTAssertTrue(c.isIdle)
    }

    // MARK: - Create form

    func testCreateFormBeginAndEnd() {
        let c = KeyboardSubstateController()
        c.beginCreateForm()
        XCTAssertEqual(c.substate, .createForm)
        c.endCreateForm()
        XCTAssertTrue(c.isIdle)
    }

    func testResetClearsAnything() {
        let c = KeyboardSubstateController()
        c.beginCreateForm()
        c.reset()
        XCTAssertTrue(c.isIdle)
    }
}
