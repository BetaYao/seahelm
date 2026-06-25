import XCTest
@testable import seahelm

final class BridgeConfirmFlowTests: XCTestCase {
    func testSuggestNextOrderExecutesImmediately() {
        XCTAssertEqual(BridgeConfirmFlow.onEnter(kind: .suggestNextOrder, expanded: false), .execute)
    }
    func testReturnToPortFirstEnterExpands() {
        XCTAssertEqual(BridgeConfirmFlow.onEnter(kind: .returnToPort, expanded: false), .expand)
    }
    func testReturnToPortSecondEnterExecutes() {
        XCTAssertEqual(BridgeConfirmFlow.onEnter(kind: .returnToPort, expanded: true), .execute)
    }
}
