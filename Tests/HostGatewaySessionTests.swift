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
    private var observers: [Int: (VTEvent) -> Void] = [:]
    private var nextToken = 1

    @discardableResult
    func addObserver(_ observer: @escaping (VTEvent) -> Void) -> Int {
        defer { nextToken += 1 }
        observers[nextToken] = observer
        return nextToken
    }

    func removeObserver(_ token: Int) { observers.removeValue(forKey: token) }

    /// Fan out to every subscriber, the way the real manager does.
    func emit(_ event: VTEvent) {
        for observer in observers.values { observer(event) }
    }

    var observerCount: Int { observers.count }

    func open(paneSessionKey: String) -> [String: Any] {
        opened.append(paneSessionKey)
        if (openResult["ok"] as? Bool) != false {
            openKeys.insert(paneSessionKey)
        }
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
        let b64 = PairingCrypto.base64url(root)
        let s = HostGatewaySession(
            router: ControlRouter(dataSource: ds),
            expectedMacId: macId,
            rootSecretBase64url: b64,
            vt: vt)
        return (s, ds, vt)
    }

    private func token() -> String {
        PairingCrypto(rootSecret: root).authPassword
    }

    private func authFrame(id: String = "auth1", tok: String? = nil) -> String {
        let t = tok ?? token()
        return #"{"id":"\#(id)","method":"auth","params":{"mac_id":"\#(macId)","token":"\#(t)"}}"#
    }

    private func decodeResponse(_ frame: HostGatewayWireFrame) -> [String: Any] {
        guard case .text(let text) = frame else {
            XCTFail("expected a text frame, got binary")
            return [:]
        }
        return try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
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

    private final class FakePairingCode: PairingCodeVerifying {
        var code: String
        init(_ code: String) { self.code = code }
        func verify(_ raw: String) -> Bool {
            PairingCodeStore(code: code).verify(raw)
        }
    }

    private func sessionWithCode(_ code: String,
                                 limiter: PairRateLimiter? = nil,
                                 ip: String = "1.1.1.1")
    -> (HostGatewaySession, SessionFakeDataSource, FakeVT) {
        let ds = SessionFakeDataSource()
        let vt = FakeVT()
        let b64 = PairingCrypto.base64url(root)
        let s = HostGatewaySession(
            router: ControlRouter(dataSource: ds),
            expectedMacId: macId,
            rootSecretBase64url: b64,
            vt: vt,
            pairingCode: FakePairingCode(code),
            rateLimiter: limiter,
            clientIP: ip)
        return (s, ds, vt)
    }

    func testAuthWithCodeSucceedsAndReturnsToken() {
        let (s, _, _) = sessionWithCode("48291736")
        let out = s.handle(text:
            #"{"id":"a","method":"auth","params":{"code":"4829 1736","vt_binary":true,"vt_deflate":true}}"#)
        XCTAssertEqual(out.count, 1)
        let result = decodeResponse(out[0])["result"] as? [String: Any]
        XCTAssertEqual(result?["ok"] as? Bool, true)
        XCTAssertEqual(result?["mac_id"] as? String, macId)
        XCTAssertEqual(result?["token"] as? String, token())
        XCTAssertEqual(result?["vt_binary"] as? Bool, true)
        XCTAssertEqual(result?["vt_deflate"] as? Bool, true)

        let snap = s.handle(text: #"{"id":"2","method":"session.snapshot","params":{}}"#)
        let snapObj = decodeResponse(snap[0])
        XCTAssertNil(snapObj["error"])
        XCTAssertNotNil(snapObj["result"])
    }

    func testAuthWithWrongCodeFails() {
        let (s, _, _) = sessionWithCode("48291736")
        let out = s.handle(text:
            #"{"id":"a","method":"auth","params":{"code":"00000000"}}"#)
        XCTAssertEqual((decodeResponse(out[0])["result"] as? [String: Any])?["ok"] as? Bool, false)
        let snap = s.handle(text: #"{"id":"2","method":"session.snapshot","params":{}}"#)
        XCTAssertEqual((decodeResponse(snap[0])["error"] as? [String: Any])?["code"] as? Int, -32001)
    }

    func testAuthCodeRateLimited() {
        let lim = PairRateLimiter(maxFailures: 2, window: 60)
        let (s, _, _) = sessionWithCode("48291736", limiter: lim, ip: "9.9.9.9")
        for _ in 0..<2 {
            _ = s.handle(text: #"{"id":"a","method":"auth","params":{"code":"00000000"}}"#)
        }
        let out = s.handle(text: #"{"id":"a","method":"auth","params":{"code":"00000000"}}"#)
        let err = decodeResponse(out[0])["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, -32029)
        XCTAssertEqual(err?["message"] as? String, "rate_limited")
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

    func testFailedVtOpenFallsBackToControlRouterForSendKeys() {
        let (s, ds, vt) = session()
        ds.knownPanes = ["pane-1"]
        vt.openResult = ["ok": false, "error": "spawn failed"]
        _ = s.handle(text: authFrame())
        _ = s.handle(text: #"{"id":"a","method":"pane.vt_open","params":{"pane_session_key":"pane-1"}}"#)
        let out = s.handle(text: #"{"id":"b","method":"pane.send_keys","params":{"pane_id":"pane-1","keys":["a"]}}"#)
        XCTAssertTrue(vt.sentKeys.isEmpty)
        XCTAssertEqual(ds.sentKeys.count, 1)
        XCTAssertEqual((decodeResponse(out[0])["result"] as? [String: Any])?["sent"] as? Bool, true)
    }

    func testVtNotifyQueued() {
        let (s, _, vt) = session()
        _ = s.handle(text: authFrame())
        _ = s.handle(text: #"{"id":"o","method":"pane.vt_open","params":{"pane_session_key":"k1"}}"#)
        vt.emit(VTEvent(kind: .data, paneSessionKey: "k1", payload: Data("a".utf8)))
        let notes = s.drainNotifications()
        XCTAssertEqual(notes.count, 1)
        let obj = decodeResponse(notes[0])
        XCTAssertEqual(obj["type"] as? String, "notify")
        XCTAssertEqual(obj["method"] as? String, "vt.data")
        XCTAssertEqual((obj["params"] as? [String: Any])?["b64"] as? String, "YQ==")
    }

    /// The regression that made a second browser tab kill the first: the shared
    /// manager held one assignable callback, so each new session overwrote the
    /// previous one's and only the newest connection ever saw a frame again.
    func testEverySessionKeepsReceivingVT() {
        let ds = SessionFakeDataSource()
        let vt = FakeVT()
        let b64 = PairingCrypto.base64url(root)
        func make() -> HostGatewaySession {
            let s = HostGatewaySession(router: ControlRouter(dataSource: ds),
                                       expectedMacId: macId, rootSecretBase64url: b64, vt: vt)
            _ = s.handle(text: authFrame())
            _ = s.handle(text: #"{"id":"o","method":"pane.vt_open","params":{"pane_session_key":"k1"}}"#)
            return s
        }
        let first = make()
        let second = make()

        vt.emit(VTEvent(kind: .data, paneSessionKey: "k1", payload: Data("a".utf8)))

        XCTAssertEqual(first.drainNotifications().count, 1, "the older session was muted")
        XCTAssertEqual(second.drainNotifications().count, 1)
    }

    /// Binary is opt-in, so a page cached from before the format still renders.
    func testBinaryVTOnlyWhenNegotiated() {
        let (s, _, vt) = session()
        _ = s.handle(text: authFrame())
        _ = s.handle(text: #"{"id":"o","method":"pane.vt_open","params":{"pane_session_key":"k1"}}"#)
        vt.emit(VTEvent(kind: .data, paneSessionKey: "k1", payload: Data(repeating: 0x41, count: 8)))
        guard case .text = s.drainNotifications()[0] else {
            return XCTFail("un-negotiated client must keep the JSON frame")
        }

        let (b, _, bvt) = session()
        let authBinary = #"{"id":"a","method":"auth","params":{"mac_id":"\#(macId)","token":"\#(token())","vt_binary":true}}"#
        let reply = decodeResponse(b.handle(text: authBinary)[0])
        XCTAssertEqual((reply["result"] as? [String: Any])?["vt_binary"] as? Bool, true)
        _ = b.handle(text: #"{"id":"o","method":"pane.vt_open","params":{"pane_session_key":"k1"}}"#)
        bvt.emit(VTEvent(kind: .data, paneSessionKey: "k1", payload: Data(repeating: 0x41, count: 8)))
        guard case .binary(let data) = b.drainNotifications()[0] else {
            return XCTFail("negotiated client should get a binary frame")
        }
        let decoded = HostGatewayVTFrame.decode(data)
        XCTAssertEqual(decoded?.paneSessionKey, "k1")
        XCTAssertEqual(decoded?.payload, Data(repeating: 0x41, count: 8))
    }

    /// A closed connection must stop costing the manager encode work.
    ///
    /// Wired the way `HostGatewayServer.accept` wires it — with a pending-outbound
    /// handler installed — because that is where the leak lived: the previous
    /// version of this test left the handler nil, so it passed against a session
    /// that retained itself and never unsubscribed in production.
    func testClosingASessionUnsubscribesIt() {
        let vt = FakeVT()
        autoreleasepool {
            let s = HostGatewaySession(router: ControlRouter(dataSource: SessionFakeDataSource()),
                                       expectedMacId: macId,
                                       rootSecretBase64url: PairingCrypto.base64url(root),
                                       vt: vt)
            s.setPendingOutboundHandler { session in _ = session.drainNotifications() }
            _ = s.handle(text: authFrame())
            XCTAssertEqual(vt.observerCount, 1)
        }
        XCTAssertEqual(vt.observerCount, 0, "a dropped session left its observer behind")
    }

    /// The server calls this when the socket dies, rather than waiting for the
    /// last reference to fall out of Network.framework's handler graph.
    func testCloseUnsubscribesWhileStillReferenced() {
        let (s, _, vt) = session()
        _ = s.handle(text: authFrame())
        XCTAssertEqual(vt.observerCount, 1)
        s.close()
        XCTAssertEqual(vt.observerCount, 0)
        _ = s.handle(text: #"{"id":"o","method":"pane.vt_open","params":{"pane_session_key":"k1"}}"#)
        vt.emit(VTEvent(kind: .data, paneSessionKey: "k1", payload: Data("a".utf8)))
        XCTAssertTrue(s.drainNotifications().isEmpty, "a closed session still queued a frame")
    }

    /// The observer is live from `init`, so without an auth gate anything that
    /// completes the WebSocket upgrade reads every pane's screen for free.
    func testNoVTBeforeAuth() {
        let (s, _, vt) = session()
        vt.emit(VTEvent(kind: .snapshot, paneSessionKey: "k1", payload: Data("secret".utf8),
                        cols: 80, rows: 24))
        vt.emit(VTEvent(kind: .data, paneSessionKey: "k1", payload: Data("secret".utf8)))
        XCTAssertTrue(s.drainNotifications().isEmpty,
                      "an unauthenticated client was queued terminal output")
    }

    /// The manager broadcasts every pane to every observer, so the session is
    /// what has to filter: one browser must not receive another browser's pane.
    func testVTOnlyReachesSessionsThatOpenedThePane() {
        let ds = SessionFakeDataSource()
        let vt = FakeVT()
        let b64 = PairingCrypto.base64url(root)
        func make(open key: String) -> HostGatewaySession {
            let s = HostGatewaySession(router: ControlRouter(dataSource: ds),
                                       expectedMacId: macId, rootSecretBase64url: b64, vt: vt)
            _ = s.handle(text: authFrame())
            _ = s.handle(text: #"{"id":"o","method":"pane.vt_open","params":{"pane_session_key":"\#(key)"}}"#)
            return s
        }
        let watchingX = make(open: "x")
        let watchingY = make(open: "y")

        vt.emit(VTEvent(kind: .data, paneSessionKey: "x", payload: Data("x-output".utf8)))

        XCTAssertEqual(watchingX.drainNotifications().count, 1)
        XCTAssertTrue(watchingY.drainNotifications().isEmpty,
                      "a session was sent a pane it never opened")
    }

    /// Closing the pane stops the stream for this client too — otherwise a
    /// `vt_close` would leave frames queueing against a terminal it disposed.
    func testVTStopsAfterPaneClose() {
        let (s, _, vt) = session()
        _ = s.handle(text: authFrame())
        _ = s.handle(text: #"{"id":"o","method":"pane.vt_open","params":{"pane_session_key":"k1"}}"#)
        _ = s.handle(text: #"{"id":"c","method":"pane.vt_close","params":{"pane_session_key":"k1"}}"#)
        vt.emit(VTEvent(kind: .data, paneSessionKey: "k1", payload: Data("a".utf8)))
        XCTAssertTrue(s.drainNotifications().isEmpty)
    }
}
