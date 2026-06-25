import XCTest
@testable import seahelm

final class GatewayStateTests: XCTestCase {

    func testInitialStateIsDisconnected() {
        let sm = GatewayStateMachine()
        XCTAssertEqual(sm.state, .disconnected)
    }

    func testDisconnectedToConnecting() {
        var sm = GatewayStateMachine()
        let changed = sm.transition(to: .connecting)
        XCTAssertTrue(changed)
        XCTAssertEqual(sm.state, .connecting)
    }

    func testConnectingToConnected() {
        var sm = GatewayStateMachine()
        sm.transition(to: .connecting)
        let changed = sm.transition(to: .connected)
        XCTAssertTrue(changed)
        XCTAssertEqual(sm.state, .connected)
    }

    func testConnectingToError() {
        var sm = GatewayStateMachine()
        sm.transition(to: .connecting)
        let changed = sm.transition(to: .error("timeout"))
        XCTAssertTrue(changed)
        if case .error(let msg) = sm.state {
            XCTAssertEqual(msg, "timeout")
        } else {
            XCTFail("Expected error state")
        }
    }

    func testErrorToConnecting() {
        var sm = GatewayStateMachine()
        sm.transition(to: .connecting)
        sm.transition(to: .error("fail"))
        let changed = sm.transition(to: .connecting)
        XCTAssertTrue(changed)
        XCTAssertEqual(sm.state, .connecting)
    }

    func testConnectedToDisconnected() {
        var sm = GatewayStateMachine()
        sm.transition(to: .connecting)
        sm.transition(to: .connected)
        let changed = sm.transition(to: .disconnected)
        XCTAssertTrue(changed)
        XCTAssertEqual(sm.state, .disconnected)
    }

    func testSameStateReturnsFalse() {
        var sm = GatewayStateMachine()
        let changed = sm.transition(to: .disconnected)
        XCTAssertFalse(changed)
    }

    func testCannotGoDirectlyToConnected() {
        var sm = GatewayStateMachine()
        let changed = sm.transition(to: .connected)
        XCTAssertFalse(changed)
        XCTAssertEqual(sm.state, .disconnected)
    }

    func testIsConnectedProperty() {
        var sm = GatewayStateMachine()
        XCTAssertFalse(sm.isConnected)
        sm.transition(to: .connecting)
        sm.transition(to: .connected)
        XCTAssertTrue(sm.isConnected)
    }
}
