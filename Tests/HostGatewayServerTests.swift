import XCTest
@testable import seahelm

private final class ServerFakeDataSource: ControlDataSource {
    var panes: [PaneSnapshot] = []

    func snapshotPanes() -> [PaneSnapshot] { panes }
    func readPane(paneId: String, source: String, lines: Int) -> String? { nil }
    func ingestHook(json: [String: Any]) -> String? { nil }
    func sendKeys(paneId: String, keys: [String]) -> Bool { false }
}

private final class ServerFakeVT: HostGatewayVTAttaching {
    var onNotify: ((String, [String: Any]) -> Void)?

    func open(paneSessionKey: String) -> [String: Any] { ["ok": true] }
    func close(paneSessionKey: String) {}
    func keepalive(paneSessionKey: String) {}
    func sendKeys(paneSessionKey: String, utf8: Data) -> Bool { false }
}

final class HostGatewayServerTests: XCTestCase {
    private let testPort: UInt16 = 27999
    private let root = Data((0..<32).map { UInt8($0) })
    private let macId = "live"

    private func waitUntilListening(_ server: HostGatewayServer, timeout: TimeInterval = 5) {
        let exp = expectation(description: "listening")
        server.start(onReady: { exp.fulfill() })
        wait(for: [exp], timeout: timeout)
        XCTAssertTrue(server.isListening, "server should be listening on port \(testPort)")
    }

    private func receiveText(from task: URLSessionWebSocketTask,
                             timeout: TimeInterval = 5) -> String {
        let exp = expectation(description: "ws receive")
        var payload = ""
        task.receive { result in
            switch result {
            case .success(.string(let text)):
                payload = text
            case .success(.data(let data)):
                payload = String(data: data, encoding: .utf8) ?? ""
            case .failure(let error):
                XCTFail("receive failed: \(error)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
        return payload
    }

    private func sendText(_ text: String, on task: URLSessionWebSocketTask, timeout: TimeInterval = 5) {
        let exp = expectation(description: "ws send")
        task.send(.string(text)) { error in
            if let error { XCTFail("send failed: \(error)") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
    }

    func testWebSocketAuthAndSnapshot() {
        let ds = ServerFakeDataSource()
        ds.panes = [PaneSnapshot(
            paneId: "t1", worktreePath: "/wt", branch: "main",
            project: "proj", agentType: "Claude Code", status: "Running",
            lastMessage: "hi")]
        let vt = ServerFakeVT()
        let b64 = MqttCrypto.base64url(root)
        let token = MqttCrypto(rootSecret: root).authPassword
        let config = HostGatewayConfig(enabled: true, port: testPort)
        let server = HostGatewayServer(
            config: config,
            router: ControlRouter(dataSource: ds),
            expectedMacId: macId,
            rootSecretBase64url: b64,
            vt: vt)
        defer { server.stop() }

        waitUntilListening(server)

        let url = URL(string: "ws://127.0.0.1:\(testPort)/ws")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        let authFrame = #"{"id":"auth1","method":"auth","params":{"mac_id":"\#(macId)","token":"\#(token)"}}"#
        sendText(authFrame, on: task)
        let authReply = receiveText(from: task)
        let authObj = try! JSONSerialization.jsonObject(with: Data(authReply.utf8)) as! [String: Any]
        XCTAssertEqual((authObj["result"] as? [String: Any])?["ok"] as? Bool, true)

        sendText(#"{"id":"snap1","method":"session.snapshot","params":{}}"#, on: task)
        let snapReply = receiveText(from: task)
        let snapObj = try! JSONSerialization.jsonObject(with: Data(snapReply.utf8)) as! [String: Any]
        XCTAssertEqual(snapObj["id"] as? String, "snap1")
        let panes = (snapObj["result"] as? [String: Any])?["panes"] as? [[String: Any]]
        XCTAssertEqual(panes?.count, 1)
        XCTAssertEqual(panes?.first?["pane_id"] as? String, "t1")

        task.cancel(with: .goingAway, reason: nil)
    }

    func testVtNotifyDeliveredOverWebSocket() {
        let ds = ServerFakeDataSource()
        let vt = ServerFakeVT()
        let b64 = MqttCrypto.base64url(root)
        let token = MqttCrypto(rootSecret: root).authPassword
        let config = HostGatewayConfig(enabled: true, port: testPort)
        let server = HostGatewayServer(
            config: config,
            router: ControlRouter(dataSource: ds),
            expectedMacId: macId,
            rootSecretBase64url: b64,
            vt: vt)
        defer { server.stop() }

        waitUntilListening(server)

        let url = URL(string: "ws://127.0.0.1:\(testPort)/ws")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        sendText(
            #"{"id":"auth2","method":"auth","params":{"mac_id":"\#(macId)","token":"\#(token)"}}"#,
            on: task)
        _ = receiveText(from: task)

        vt.onNotify?("vt.data", ["pane_session_key": "k1", "b64": "YQ=="])

        let noteReply = receiveText(from: task)
        let noteObj = try! JSONSerialization.jsonObject(with: Data(noteReply.utf8)) as! [String: Any]
        XCTAssertEqual(noteObj["type"] as? String, "notify")
        XCTAssertEqual(noteObj["method"] as? String, "vt.data")

        task.cancel(with: .goingAway, reason: nil)
    }

    /// The page has to come off the same port as `/ws`, or the browser client is
    /// left on a foreign origin where `crypto.subtle` does not exist.
    func testStaticPageServedFromSamePort() throws {
        let webRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gateway-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: webRoot, withIntermediateDirectories: true)
        try Data("<html>cockpit</html>".utf8).write(to: webRoot.appendingPathComponent("index.html"))
        defer { try? FileManager.default.removeItem(at: webRoot) }

        let server = HostGatewayServer(
            config: HostGatewayConfig(enabled: true, port: testPort, webRoot: webRoot.path),
            router: ControlRouter(dataSource: ServerFakeDataSource()),
            expectedMacId: macId,
            rootSecretBase64url: MqttCrypto.base64url(root),
            vt: ServerFakeVT())
        defer { server.stop() }

        waitUntilListening(server)

        let exp = expectation(description: "http get")
        var status = -1
        var body = ""
        var contentType = ""
        let task = URLSession.shared.dataTask(
            with: URL(string: "http://127.0.0.1:\(testPort)/")!
        ) { data, response, error in
            if let error { XCTFail("GET failed: \(error)") }
            if let http = response as? HTTPURLResponse {
                status = http.statusCode
                contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            }
            body = String(decoding: data ?? Data(), as: UTF8.self)
            exp.fulfill()
        }
        task.resume()
        wait(for: [exp], timeout: 10)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, "<html>cockpit</html>")
        XCTAssertTrue(contentType.hasPrefix("text/html"), "got \(contentType)")
    }

    /// Static hosting must not become a file server for the rest of the disk.
    func testUnknownPathIs404() throws {
        let server = HostGatewayServer(
            config: HostGatewayConfig(enabled: true, port: testPort, webRoot: NSTemporaryDirectory()),
            router: ControlRouter(dataSource: ServerFakeDataSource()),
            expectedMacId: macId,
            rootSecretBase64url: MqttCrypto.base64url(root),
            vt: ServerFakeVT())
        defer { server.stop() }

        waitUntilListening(server)

        let exp = expectation(description: "http 404")
        var status = -1
        let task = URLSession.shared.dataTask(
            with: URL(string: "http://127.0.0.1:\(testPort)/definitely-not-here.js")!
        ) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            exp.fulfill()
        }
        task.resume()
        wait(for: [exp], timeout: 10)

        XCTAssertEqual(status, 404)
    }
}
