import XCTest
@testable import seahelm

final class WebhookStatusProviderSuggestTests: XCTestCase {
    private func makeEvent(_ type: WebhookEventType, cwd: String, data: [String: Any]?) -> WebhookEvent {
        WebhookEvent(source: "seahelm-suggest", sessionId: "s1", event: type,
                     cwd: cwd, timestamp: nil, data: data)
    }

    func testSuggestFiresCallbackWithOptions() {
        let provider = WebhookStatusProvider()
        provider.updateWorktrees(["/repo/feat-x"])
        let exp = expectation(description: "onSuggestions")
        var received: (String, [String])?
        provider.onSuggestions = { path, options in received = (path, options); exp.fulfill() }

        provider.handleEvent(makeEvent(.suggest, cwd: "/repo/feat-x", data: ["options": ["a", "b"]]))

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received?.0, "/repo/feat-x")
        XCTAssertEqual(received?.1, ["a", "b"])
        // suggest must not create a session / change status
        XCTAssertEqual(provider.status(for: "/repo/feat-x"), .unknown)
    }

    func testSuggestUnknownWorktreeIsIgnored() {
        let provider = WebhookStatusProvider()
        provider.updateWorktrees(["/repo/feat-x"])
        var fired = false
        provider.onSuggestions = { _, _ in fired = true }
        provider.handleEvent(makeEvent(.suggest, cwd: "/somewhere/else", data: ["options": ["a"]]))
        // give the (non-)dispatch a chance to run
        let pause = expectation(description: "pause"); DispatchQueue.main.async { pause.fulfill() }
        wait(for: [pause], timeout: 1.0)
        XCTAssertFalse(fired)
    }

    func testUserPromptClearsSuggestions() {
        let provider = WebhookStatusProvider()
        provider.updateWorktrees(["/repo/feat-x"])
        let exp = expectation(description: "cleared")
        var received: [String]?
        provider.onSuggestions = { _, options in received = options; exp.fulfill() }
        provider.handleEvent(makeEvent(.userPrompt, cwd: "/repo/feat-x", data: ["prompt": "go"]))
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received, [])
    }
}
