import XCTest
@testable import seahelm

private final class FakeDataSource: ControlDataSource {
    var panes: [PaneSnapshot] = []
    var reads: [String: String] = [:]
    var ingested: [[String: Any]] = []
    var blockReturn: String?
    func snapshotPanes() -> [PaneSnapshot] { panes }
    func readPane(paneId: String, source: String, lines: Int) -> String? { reads[paneId] }
    func ingestHook(json: [String: Any]) -> String? { ingested.append(json); return blockReturn }
}

final class ControlRouterTests: XCTestCase {

    private func router() -> (ControlRouter, FakeDataSource) {
        let ds = FakeDataSource()
        return (ControlRouter(dataSource: ds), ds)
    }

    func testPing() {
        let (r, _) = router()
        guard case .ok(let d) = r.handle(method: "ping", params: [:]) else { return XCTFail() }
        XCTAssertEqual(d["pong"] as? Bool, true)
    }

    func testUnknownMethod() {
        let (r, _) = router()
        guard case .error(let code, _) = r.handle(method: "bogus.x", params: [:]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.methodNotFound)
    }

    func testSnapshot() {
        let (r, ds) = router()
        ds.panes = [PaneSnapshot(paneId: "t1", worktreePath: "/wt", branch: "main",
                                 project: "proj", agentType: "Claude Code", status: "Running",
                                 lastMessage: "hi")]
        guard case .ok(let d) = r.handle(method: "session.snapshot", params: [:]),
              let panes = d["panes"] as? [[String: Any]] else { return XCTFail() }
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes[0]["pane_id"] as? String, "t1")
        XCTAssertEqual(panes[0]["status"] as? String, "Running")
    }

    func testReadPaneOk() {
        let (r, ds) = router()
        ds.reads["t1"] = "line1\nline2"
        guard case .ok(let d) = r.handle(method: "pane.read", params: ["pane_id": "t1"]) else { return XCTFail() }
        XCTAssertEqual(d["text"] as? String, "line1\nline2")
    }

    func testReadPaneMissingParam() {
        let (r, _) = router()
        guard case .error(let code, _) = r.handle(method: "pane.read", params: [:]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.invalidParams)
    }

    func testReadPaneNotFound() {
        let (r, _) = router()
        guard case .error(let code, _) = r.handle(method: "pane.read", params: ["pane_id": "nope"]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.notFound)
    }

    func testSuggestBuildsPayload() {
        let (r, ds) = router()
        guard case .ok(let d) = r.handle(method: "suggest",
                params: ["options": ["a", "b"], "cwd": "/wt", "pane_id": "t1"]) else { return XCTFail() }
        XCTAssertEqual(d["accepted"] as? Bool, true)
        XCTAssertEqual(ds.ingested.count, 1)
        let sent = ds.ingested[0]
        XCTAssertEqual(sent["event"] as? String, "suggest")
        XCTAssertEqual(sent["cwd"] as? String, "/wt")
        XCTAssertEqual(sent["pane_id"] as? String, "t1")
        XCTAssertEqual((sent["data"] as? [String: Any])?["options"] as? [String], ["a", "b"])
    }

    func testSuggestRequiresOptions() {
        let (r, _) = router()
        guard case .error(let code, _) = r.handle(method: "suggest", params: [:]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.invalidParams)
    }

    func testHookForwardsRaw() {
        let (r, ds) = router()
        _ = r.handle(method: "hook", params: ["event": "agent_stop", "session_id": "s1", "cwd": "/x"])
        XCTAssertEqual(ds.ingested.count, 1)
        XCTAssertEqual(ds.ingested[0]["event"] as? String, "agent_stop")
    }

    func testHookReturnsBlockAsBase64() {
        let (r, ds) = router()
        ds.blockReturn = #"{"decision":"block","reason":"go"}"#
        guard case .ok(let d) = r.handle(method: "hook", params: ["event": "agent_stop"]),
              let b64 = d["block_b64"] as? String,
              let decoded = Data(base64Encoded: b64) else { return XCTFail() }
        XCTAssertEqual(String(data: decoded, encoding: .utf8), #"{"decision":"block","reason":"go"}"#)
    }

    func testHookNoBlockOmitsField() {
        let (r, ds) = router()
        ds.blockReturn = nil
        guard case .ok(let d) = r.handle(method: "hook", params: ["event": "agent_stop"]) else { return XCTFail() }
        XCTAssertNil(d["block_b64"])
    }

    func testParseRequest() {
        let req = ControlRouter.parseRequest(#"{"id":"r1","method":"pane.read","params":{"pane_id":"t1"}}"#)
        XCTAssertEqual(req?.id, "r1")
        XCTAssertEqual(req?.method, "pane.read")
        XCTAssertEqual(req?.params["pane_id"] as? String, "t1")
    }

    func testParseRequestMalformed() {
        XCTAssertNil(ControlRouter.parseRequest("not json"))
        XCTAssertNil(ControlRouter.parseRequest(#"{"id":"r1"}"#))  // no method
    }

    func testEncodeResponseRoundTrip() {
        let line = ControlRouter.encodeResponse(id: "r1", result: .ok(["pong": true]))
        XCTAssertTrue(line.hasSuffix("\n"))
        let obj = try! JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["id"] as? String, "r1")
        XCTAssertEqual((obj["result"] as? [String: Any])?["pong"] as? Bool, true)
    }

    func testEncodeError() {
        let line = ControlRouter.encodeResponse(id: "r2", result: .error(code: -32601, message: "nope"))
        let obj = try! JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as! [String: Any]
        let err = obj["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, -32601)
        XCTAssertEqual(err?["message"] as? String, "nope")
    }
}
