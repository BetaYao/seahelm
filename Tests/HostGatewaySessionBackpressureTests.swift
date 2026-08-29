import XCTest
@testable import seahelm

final class HostGatewaySessionBackpressureTests: XCTestCase {
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

    final class FakeVT: HostGatewayVTAttaching {
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

        func emit(_ event: VTEvent) {
            for observer in observers.values { observer(event) }
        }

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

    private func authFrame(id: String = "auth1") -> String {
        #"{"id":"\#(id)","method":"auth","params":{"mac_id":"\#(macId)","token":"\#(token())"}}"#
    }

    private func decodeResponse(_ frame: HostGatewayWireFrame) -> [String: Any] {
        guard case .text(let text) = frame else {
            XCTFail("expected a text frame, got binary")
            return [:]
        }
        return try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    private func openAuthenticated(_ s: HostGatewaySession, vtKey: String = "k1") {
        _ = s.handle(text: authFrame())
        _ = s.handle(text: #"{"id":"o","method":"pane.vt_open","params":{"pane_session_key":"\#(vtKey)"}}"#)
    }

    private func methods(of frames: [HostGatewayWireFrame]) -> [String] {
        frames.compactMap { decodeResponse($0)["method"] as? String }
    }

    private func vtPayloadBytes(of frames: [HostGatewayWireFrame]) -> Int {
        vtNotifies(of: frames).reduce(0) { $0 + $1.payload.count }
    }

    private func vtNotifies(of frames: [HostGatewayWireFrame]) -> [(method: String, payload: Data)] {
        frames.compactMap { frame in
            let obj = decodeResponse(frame)
            guard let method = obj["method"] as? String,
                  method == "vt.data" || method == "vt.snapshot",
                  let b64 = (obj["params"] as? [String: Any])?["b64"] as? String,
                  let data = Data(base64Encoded: b64) else { return nil }
            return (method, data)
        }
    }

    private func taggedChunk(_ id: UInt8, count: Int = 32 * 1024) -> Data {
        var data = Data(repeating: 0x41, count: count)
        data[0] = id
        return data
    }

    private func openedDecision() -> HostGatewayDecisions.Change {
        .opened(HostGatewayDecisions.Decision(
            paneSessionKey: "k1", paneId: "p1", kind: "question",
            prompt: "ok?", options: ["yes"], seq: 1))
    }

    func testHighPriorityDrainsBeforeVT() {
        let (s, _, vt) = session()
        openAuthenticated(s)
        vt.emit(VTEvent(kind: .data, paneSessionKey: "k1", payload: Data("a".utf8)))
        s.pushDecision(.opened(HostGatewayDecisions.Decision(
            paneSessionKey: "k1", paneId: "p1", kind: "question",
            prompt: "ok?", options: ["yes"], seq: 1)))

        let notes = s.drainNotifications()
        let methods = methods(of: notes)
        XCTAssertEqual(methods.first, "pane.event",
                       "high-priority pane.event must drain before queued VT")
        XCTAssertTrue(methods.contains("vt.data"))
        let firstVT = methods.firstIndex { $0.hasPrefix("vt.") }
        XCTAssertEqual(firstVT, 1)
        XCTAssertEqual(methods, ["pane.event", "vt.data"])
    }

    func testDropsOldVTWhenOverBudget() {
        let (s, _, vt) = session()
        openAuthenticated(s)
        s.pushDecision(openedDecision())
        for i in 0..<8 {
            vt.emit(VTEvent(kind: .data, paneSessionKey: "k1", payload: taggedChunk(UInt8(i))))
        }

        let notes = s.drainNotifications()
        let names = methods(of: notes)
        XCTAssertEqual(names.first, "pane.event",
                       "high-priority frame must drain first and survive VT flood")
        XCTAssertEqual(names.filter { $0 == "pane.event" }.count, 1)

        let data = vtNotifies(of: notes).filter { $0.method == "vt.data" }
        XCTAssertEqual(data.map { $0.payload.first }, [4, 5, 6, 7],
                       "drop-old must keep the newest chunks, not the oldest")
        XCTAssertFalse(data.contains { ($0.payload.first ?? 0) < 4 })

        let vtBytes = vtPayloadBytes(of: notes)
        XCTAssertLessThanOrEqual(vtBytes, 256 * 1024)
        XCTAssertLessThanOrEqual(vtBytes, 128 * 1024)
        XCTAssertEqual(names.last, "vt.snapshot",
                       "overflow must leave a resync snapshot at the end")
    }

    func testKeepsQueuedSnapshotInsteadOfEmptyResync() {
        let (s, _, vt) = session()
        openAuthenticated(s)
        let screen = Data("SCREEN".utf8)
        vt.emit(VTEvent(kind: .snapshot, paneSessionKey: "k1", payload: screen))
        for i in 0..<8 {
            vt.emit(VTEvent(kind: .data, paneSessionKey: "k1", payload: taggedChunk(UInt8(i))))
        }

        let notes = s.drainNotifications()
        let snaps = vtNotifies(of: notes).filter { $0.method == "vt.snapshot" }
        XCTAssertEqual(snaps.count, 1, "must not append an empty synthetic over a real snapshot")
        XCTAssertEqual(snaps.first?.payload, screen)
        XCTAssertEqual(methods(of: notes).last, "vt.snapshot")
        XCTAssertFalse(snaps.contains { $0.payload.isEmpty })
    }

    func testResyncRateLimited() {
        let (s, _, vt) = session()
        openAuthenticated(s)
        let chunk = Data(repeating: 0x42, count: 64 * 1024)
        for _ in 0..<5 {
            vt.emit(VTEvent(kind: .data, paneSessionKey: "k1", payload: chunk))
        }

        let snapshots = methods(of: s.drainNotifications()).filter { $0 == "vt.snapshot" }
        XCTAssertEqual(snapshots.count, 1, "two overflows within 1s must share one snapshot")
    }
}
