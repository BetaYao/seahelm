import XCTest
@testable import seahelm

final class WebhookServerTests: XCTestCase {

    var server: WebhookServer!
    let lock = NSLock()
    var _receivedEvents: [WebhookEvent] = []
    var receivedEvents: [WebhookEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedEvents
    }
    let testPort: UInt16 = 17070  // avoid conflict with running seahelm

    override func setUp() {
        super.setUp()
        _receivedEvents = []
        server = WebhookServer(port: testPort) { [weak self] event in
            guard let self = self else { return nil }
            self.lock.lock()
            self._receivedEvents.append(event)
            self.lock.unlock()
            return nil
        }
    }

    override func tearDown() {
        server.stop()
        super.tearDown()
    }

    func testServerReceivesValidEvent() throws {
        server.start()
        let expectation = expectation(description: "event received")

        let json = """
        {"source":"test","session_id":"s1","event":"session_start","cwd":"/tmp"}
        """.data(using: .utf8)!

        postToWebhook(body: json) { statusCode in
            XCTAssertEqual(statusCode, 200)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(receivedEvents.count, 1)
        XCTAssertEqual(receivedEvents.first?.event, .sessionStart)
    }

    func testServerRejects404ForWrongPath() throws {
        server.start()
        let expectation = expectation(description: "response received")

        let json = "{}".data(using: .utf8)!
        postToURL("http://localhost:\(testPort)/wrong", body: json) { statusCode in
            XCTAssertEqual(statusCode, 404)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(receivedEvents.count, 0)
    }

    func testServerRejects400ForMalformedJSON() throws {
        server.start()
        let expectation = expectation(description: "response received")

        let json = "not json".data(using: .utf8)!
        postToWebhook(body: json) { statusCode in
            XCTAssertEqual(statusCode, 400)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(receivedEvents.count, 0)
    }

    func testServerRejects404ForGetRequest() throws {
        server.start()
        let expectation = expectation(description: "response received")

        var request = URLRequest(url: URL(string: "http://localhost:\(testPort)/webhook")!)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            XCTAssertEqual(statusCode, 404)
            expectation.fulfill()
        }.resume()

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(receivedEvents.count, 0)
    }

    func testServerHandlesClaudeCodeNativeFormat() throws {
        server.start()
        let expectation = expectation(description: "event received")

        let json = """
        {"hook_event_name":"PreToolUse","session_id":"sess_abc","cwd":"/tmp","tool_name":"Bash"}
        """.data(using: .utf8)!

        postToWebhook(body: json) { statusCode in
            XCTAssertEqual(statusCode, 200)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(receivedEvents.count, 1)
        XCTAssertEqual(receivedEvents.first?.source, "claude-code")
        XCTAssertEqual(receivedEvents.first?.event, .toolUseStart)
    }

    // MARK: - Helpers

    private func postToWebhook(body: Data, completion: @escaping (Int) -> Void) {
        postToURL("http://localhost:\(testPort)/webhook", body: body, completion: completion)
    }

    private func postToURL(_ urlString: String, body: Data, completion: @escaping (Int) -> Void) {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion(statusCode)
        }.resume()
    }
}
