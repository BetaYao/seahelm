import XCTest
@testable import seahelm

final class StopHookResponderTests: XCTestCase {
    private func stop(active: Bool?) -> WebhookEvent {
        var data: [String: Any] = [:]
        if let active { data["stop_hook_active"] = active }
        return WebhookEvent(source: "claude-code", sessionId: "s", event: .agentStop,
                            cwd: "/wt", timestamp: nil, data: data.isEmpty ? nil : data)
    }

    func testFirstStopBlocks() {
        let body = StopHookResponder.blockBody(for: stop(active: false), suggestOnStop: true)
        XCTAssertNotNil(body)
        XCTAssertTrue(body!.contains("\"decision\":\"block\""))
        XCTAssertTrue(body!.contains("seahelm-suggest"))
    }

    func testSecondStopDoesNotBlock() {
        XCTAssertNil(StopHookResponder.blockBody(for: stop(active: true), suggestOnStop: true))
    }

    func testMissingFlagTreatedAsFirstStop() {
        XCTAssertNotNil(StopHookResponder.blockBody(for: stop(active: nil), suggestOnStop: true))
    }

    func testDisabledNeverBlocks() {
        XCTAssertNil(StopHookResponder.blockBody(for: stop(active: false), suggestOnStop: false))
    }

    func testNonStopEventNeverBlocks() {
        let e = WebhookEvent(source: "claude-code", sessionId: "s", event: .toolUseStart,
                             cwd: "/wt", timestamp: nil, data: nil)
        XCTAssertNil(StopHookResponder.blockBody(for: e, suggestOnStop: true))
    }
}
