import XCTest
@testable import seahelm

private final class SessionFakeDataSource: ControlDataSource {
    var panes: [PaneSnapshot] = []
    var knownPanes: Set<String> = []
    var sentKeys: [(pane: String, keys: [String])] = []

    func snapshotPanes() -> [PaneSnapshot] { panes }
    func readPane(paneId: String, source: String, lines: Int) -> String? { nil }
    func ingestHook(json: [String: Any]) -> String? { nil }
    func sendKeys(paneId: String, keys: [String]) -> Bool {
        guard knownPanes.contains(paneId) else { return false }
        sentKeys.append((paneId, keys))
        return true
    }
}

private final class FakeVT: HostGatewayVTAttaching {
    var openKeys: Set<String> = []
    var opened: [String] = []
    var closed: [String] = []
    var keepalives: [String] = []
    var sentKeys: [(key: String, utf8: Data)] = []
    var openResult: [String: Any] = ["ok": true]
    var onNotify: ((String, [String: Any]) -> Void)?

    func open(paneSessionKey: String) -> [String: Any] {
        opened.append(paneSessionKey)
        openKeys.insert(paneSessionKey)
        return openResult
    }

    func close(paneSessionKey: String) {
        closed.append(paneSessionKey)
        openKeys.remove(paneSessionKey)
    }

    func keepalive(paneSessionKey: String) {
        keepalives.append(paneSessionKey)
    }

    func sendKeys(paneSessionKey: String, utf8: Data) -> Bool {
        guard openKeys.contains(paneSessionKey) else { return false }
        sentKeys.append((paneSessionKey, utf8))
        return true
    }
}

final class HostGatewaySessionTests: XCTestCase {
    private let root = Data((0..<32).map { UInt8($0) })
    private let macId = "live"

    private func session() -> (HostGatewaySession, SessionFakeDataSource, FakeVT) {
        let ds = SessionFakeDataSource()
        let vt = FakeVT()
        let b64 = MqttCrypto.base64url(root)
        let s = HostGatewaySession(
            router: ControlRouter(dataSource: ds),
            expectedMacId: macId,
            rootSecretBase64url: b64,
            vt: vt)
        return (s, ds, vt)
    }

    private func token() -> String {
        MqttCrypto(rootSecret: root).authPassword
    }

    private func authFrame(id: String = "auth1", tok: String? = nil) -> String {
        let t = tok ?? token()
        return #"{"id":"\#(id)","method":"auth","params":{"mac_id":"\#(macId)","token":"\#(t)"}}"#
    }

    private func decodeResponse(_ frame: String) -> [String: Any] {
        let obj = try! JSONSerialization.jsonObject(with: Data(frame.utf8)) as! [String: Any]
        return obj
    }

    func testRejectsSnapshotBeforeAuth() {
        let (s, _, _) = session()
        let out = s.handle(text: #"{"id":"1","method":"session.snapshot","params":{}}"#)
        XCTAssertEqual(out.count, 1)
        let obj = decodeResponse(out[0])
        XCTAssertEqual(obj["id"] as? String, "1")
        let err = obj["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, -32001)
        XCTAssertEqual(err?["message"] as? String, "unauthorized")
    }

    func testAuthSuccess() {
        let (s, _, _) = session()
        let out = s.handle(text: authFrame())
        XCTAssertEqual(out.count, 1)
        let obj = decodeResponse(out[0])
        XCTAssertEqual((obj["result"] as? [String: Any])?["ok"] as? Bool, true)
    }

    func testWrongTokenFails() {
        let (s, _, _) = session()
        let out = s.handle(text: authFrame(tok: "bad"))
        XCTAssertEqual(out.count, 1)
        let obj = decodeResponse(out[0])
        XCTAssertEqual((obj["result"] as? [String: Any])?["ok"] as? Bool, false)
    }

    func testSnapshotAfterAuthCallsRouter() {
        let (s, ds, _) = session()
        ds.panes = [PaneSnapshot(paneId: "t1", worktreePath: "/wt", branch: "main",
                                 project: "proj", agentType: "Claude Code", status: "Running",
                                 lastMessage: "hi")]
        _ = s.handle(text: authFrame())
        let out = s.handle(text: #"{"id":"2","method":"session.snapshot","params":{}}"#)
        XCTAssertEqual(out.count, 1)
        let obj = decodeResponse(out[0])
        let panes = (obj["result"] as? [String: Any])?["panes"] as? [[String: Any]]
        XCTAssertEqual(panes?.count, 1)
        XCTAssertEqual(panes?.first?["pane_id"] as? String, "t1")
    }

    func testMalformedReturnsParseError() {
        let (s, _, _) = session()
        let out = s.handle(text: "not json")
        XCTAssertEqual(out.count, 1)
        let obj = decodeResponse(out[0])
        let err = obj["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, ControlError.parse)
    }

    func testSendKeysUsesRouterWhenVTClosed() {
        let (s, ds, _) = session()
        ds.knownPanes = ["t1"]
        _ = s.handle(text: authFrame())
        _ = s.handle(text: #"{"id":"3","method":"pane.send_keys","params":{"pane_id":"t1","keys":["enter"]}}"#)
        XCTAssertEqual(ds.sentKeys.count, 1)
        XCTAssertEqual(ds.sentKeys[0].keys, ["enter"])
    }

    func testSendKeysUsesVTWhenOpen() {
        let (s, ds, vt) = session()
        ds.knownPanes = ["t1"]
        _ = s.handle(text: authFrame())
        _ = s.handle(text: #"{"id":"4","method":"pane.vt_open","params":{"pane_session_key":"t1"}}"#)
        _ = s.handle(text: #"{"id":"5","method":"pane.send_keys","params":{"pane_session_key":"t1","text":"hi"}}"#)
        XCTAssertTrue(ds.sentKeys.isEmpty)
        XCTAssertEqual(vt.sentKeys.count, 1)
        XCTAssertEqual(String(data: vt.sentKeys[0].utf8, encoding: .utf8), "hi")
    }

    func testSendKeysVTAcceptsBase64() {
        let (s, _, vt) = session()
        _ = s.handle(text: authFrame())
        _ = s.handle(text: #"{"id":"6","method":"pane.vt_open","params":{"pane_session_key":"p9"}}"#)
        _ = s.handle(text: #"{"id":"7","method":"pane.send_keys","params":{"pane_session_key":"p9","b64":"YQ=="}}"#)
        XCTAssertEqual(vt.sentKeys[0].utf8, Data([0x61]))
    }

    func testVtOpenCloseKeepalive() {
        let (s, _, vt) = session()
        _ = s.handle(text: authFrame())
        let openOut = s.handle(text: #"{"id":"8","method":"pane.vt_open","params":{"pane_session_key":"k1"}}"#)
        XCTAssertEqual((decodeResponse(openOut[0])["result"] as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertEqual(vt.opened, ["k1"])
        _ = s.handle(text: #"{"id":"9","method":"pane.vt_keepalive","params":{"pane_session_key":"k1"}}"#)
        XCTAssertEqual(vt.keepalives, ["k1"])
        _ = s.handle(text: #"{"id":"10","method":"pane.vt_close","params":{"pane_session_key":"k1"}}"#)
        XCTAssertEqual(vt.closed, ["k1"])
    }

    func testVtNotifyQueued() {
        let (s, _, vt) = session()
        _ = s.handle(text: authFrame())
        vt.onNotify?("vt.data", ["pane_session_key": "k1", "b64": "YQ=="])
        let notes = s.drainNotifications()
        XCTAssertEqual(notes.count, 1)
        let obj = decodeResponse(notes[0])
        XCTAssertEqual(obj["type"] as? String, "notify")
        XCTAssertEqual(obj["method"] as? String, "vt.data")
    }
}
