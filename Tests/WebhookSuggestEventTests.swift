import XCTest
@testable import seahelm

final class WebhookSuggestEventTests: XCTestCase {
    func testParsesSuggestEventWithOptions() throws {
        let json = """
        {"source":"seahelm-suggest","session_id":"s1","event":"suggest",
         "cwd":"/repo/feat-x","data":{"options":["run tests","open PR"]}}
        """
        let event = try WebhookEvent.parse(from: Data(json.utf8))
        XCTAssertEqual(event.event, .suggest)
        XCTAssertEqual(event.cwd, "/repo/feat-x")
        XCTAssertEqual(event.data?["options"] as? [String], ["run tests", "open PR"])
    }

    func testSuggestStatusIsUnknown() {
        XCTAssertEqual(WebhookEventType.suggest.agentStatus(data: nil), .unknown)
    }
}
