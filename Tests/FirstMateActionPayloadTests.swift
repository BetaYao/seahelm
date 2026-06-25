import XCTest
@testable import seahelm

final class FirstMateActionPayloadTests: XCTestCase {
    func testActionCarriesPayload() {
        let a = FirstMateAction(kind: .broadcastOrder, zone: .red, worktreePath: "",
                                branch: "", project: "", terminalID: "", message: "broadcast to 3",
                                payload: "run the tests")
        XCTAssertEqual(a.kind, .broadcastOrder)
        XCTAssertEqual(a.payload, "run the tests")
    }

    func testDefaultPayloadIsNil() {
        let a = FirstMateAction(kind: .returnToPort, zone: .red, worktreePath: "/w",
                                branch: "b", project: "p", terminalID: "t", message: "m")
        XCTAssertNil(a.payload)
    }
}
