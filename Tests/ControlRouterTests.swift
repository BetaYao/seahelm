import XCTest
@testable import seahelm

private final class FakeDataSource: ControlDataSource {
    var panes: [PaneSnapshot] = []
    var reads: [String: String] = [:]
    var ingested: [[String: Any]] = []
    var blockReturn: String?
    var sentText: [(pane: String, text: String, enter: Bool)] = []
    var sentKeys: [(pane: String, keys: [String])] = []
    var statuses: [String: String] = [:]
    var knownPanes: Set<String> = []
    func snapshotPanes() -> [PaneSnapshot] { panes }
    func readPane(paneId: String, source: String, lines: Int) -> String? { reads[paneId] }
    func ingestHook(json: [String: Any]) -> String? { ingested.append(json); return blockReturn }
    func sendText(paneId: String, text: String, enter: Bool) -> Bool {
        guard knownPanes.contains(paneId) else { return false }
        sentText.append((paneId, text, enter)); return true
    }
    func sendKeys(paneId: String, keys: [String]) -> Bool {
        guard knownPanes.contains(paneId) else { return false }
        sentKeys.append((paneId, keys)); return true
    }
    func paneStatus(paneId: String) -> String? { statuses[paneId] }
    var splitCalls: [(pane: String?, direction: String, focus: Bool)] = []
    var splitResult: String? = "new-pane"
    func splitPane(paneId: String?, direction: String, focus: Bool) -> String? {
        splitCalls.append((paneId, direction, focus)); return splitResult
    }
    var closed: [String] = []
    var focused: [String] = []
    var mutableOk = true
    func closePane(paneId: String) -> Bool { closed.append(paneId); return mutableOk }
    func focusPane(paneId: String) -> Bool { focused.append(paneId); return mutableOk }
    var explains: [String: [String: Any]] = [:]
    func explainPane(paneId: String) -> [String: Any]? { explains[paneId] }
    var options: [String: [[String: Any]]] = [:]
    var knownForOptions: Set<String> = []
    func paneOptions(paneId: String) -> [[String: Any]]? {
        knownForOptions.contains(paneId) ? (options[paneId] ?? []) : nil
    }
    var exportResult: [String: Any]?
    var appliedRoots: [[String: Any]] = []
    var applyOk = true
    func exportLayout() -> [String: Any]? { exportResult }
    func applyLayout(root: [String: Any]) -> Bool { appliedRoots.append(root); return applyOk }
    var zoomCalls: [(pane: String?, mode: String)] = []
    var zoomResult: [String: Any]? = ["zoomed": true]
    func zoomPane(paneId: String?, mode: String) -> [String: Any]? {
        zoomCalls.append((paneId, mode)); return zoomResult
    }
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

    // MARK: - Write channel

    func testSendTextTypesWithoutEnter() {
        let (r, ds) = router()
        ds.knownPanes = ["t1"]
        guard case .ok(let d) = r.handle(method: "pane.send_text",
                params: ["pane_id": "t1", "text": "hello"]) else { return XCTFail() }
        XCTAssertEqual(d["sent"] as? Bool, true)
        XCTAssertEqual(ds.sentText.count, 1)
        XCTAssertEqual(ds.sentText[0].text, "hello")
        XCTAssertFalse(ds.sentText[0].enter)
    }

    func testRunSubmitsWithEnter() {
        let (r, ds) = router()
        ds.knownPanes = ["t1"]
        _ = r.handle(method: "pane.run", params: ["pane_id": "t1", "command": "npm test"])
        XCTAssertEqual(ds.sentText[0].text, "npm test")
        XCTAssertTrue(ds.sentText[0].enter)
    }

    func testSendTextUnknownPane() {
        let (r, _) = router()
        guard case .error(let code, _) = r.handle(method: "pane.send_text",
                params: ["pane_id": "nope", "text": "x"]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.notFound)
    }

    func testSendKeysArray() {
        let (r, ds) = router()
        ds.knownPanes = ["t1"]
        _ = r.handle(method: "pane.send_keys", params: ["pane_id": "t1", "keys": ["escape", "ctrl+c"]])
        XCTAssertEqual(ds.sentKeys[0].keys, ["escape", "ctrl+c"])
    }

    func testSendKeysStringCoerced() {
        let (r, ds) = router()
        ds.knownPanes = ["t1"]
        _ = r.handle(method: "pane.send_keys", params: ["pane_id": "t1", "keys": "enter"])
        XCTAssertEqual(ds.sentKeys[0].keys, ["enter"])
    }

    func testSendKeysRequiresKeys() {
        let (r, ds) = router()
        ds.knownPanes = ["t1"]
        guard case .error(let code, _) = r.handle(method: "pane.send_keys",
                params: ["pane_id": "t1"]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.invalidParams)
    }

    // MARK: - Options

    func testPaneOptions() {
        let (r, ds) = router()
        ds.knownForOptions = ["t1"]
        ds.options["t1"] = [["index": 1, "label": "Yes", "selected": true],
                            ["index": 2, "label": "No", "selected": false]]
        guard case .ok(let d) = r.handle(method: "pane.options", params: ["pane_id": "t1"]),
              let opts = d["options"] as? [[String: Any]] else { return XCTFail() }
        XCTAssertEqual(opts.count, 2)
        XCTAssertEqual(opts[0]["label"] as? String, "Yes")
    }

    func testPaneOptionsUnknownPane() {
        let (r, _) = router()
        guard case .error(let code, _) = r.handle(method: "pane.options", params: ["pane_id": "nope"]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.notFound)
    }

    // MARK: - Zoom

    func testZoomTogglesByDefault() {
        let (r, ds) = router()
        ds.zoomResult = ["zoomed": true]
        guard case .ok(let d) = r.handle(method: "pane.zoom", params: ["pane_id": "t1"]) else { return XCTFail() }
        XCTAssertEqual(d["zoomed"] as? Bool, true)
        XCTAssertEqual(ds.zoomCalls[0].mode, "toggle")
        XCTAssertEqual(ds.zoomCalls[0].pane, "t1")
    }

    func testZoomModeOnAndInvalid() {
        let (r, ds) = router()
        _ = r.handle(method: "pane.zoom", params: ["mode": "on"])
        XCTAssertEqual(ds.zoomCalls[0].mode, "on")
        XCTAssertNil(ds.zoomCalls[0].pane)  // focused
        guard case .error(let code, _) = r.handle(method: "pane.zoom", params: ["mode": "sideways"]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.invalidParams)
    }

    func testZoomNotFound() {
        let (r, ds) = router()
        ds.zoomResult = nil
        guard case .error(let code, _) = r.handle(method: "pane.zoom", params: ["pane_id": "nope"]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.notFound)
    }

    // MARK: - Layout

    func testLayoutExport() {
        let (r, ds) = router()
        ds.exportResult = ["root": ["type": "pane"], "worktree_path": "/wt"]
        guard case .ok(let d) = r.handle(method: "layout.export", params: [:]) else { return XCTFail() }
        XCTAssertEqual(d["worktree_path"] as? String, "/wt")
    }

    func testLayoutExportNoActive() {
        let (r, _) = router()
        guard case .error(let code, _) = r.handle(method: "layout.export", params: [:]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.notFound)
    }

    func testLayoutApply() {
        let (r, ds) = router()
        let root: [String: Any] = ["type": "pane", "command": "claude"]
        guard case .ok(let d) = r.handle(method: "layout.apply", params: ["root": root]) else { return XCTFail() }
        XCTAssertEqual(d["applied"] as? Bool, true)
        XCTAssertEqual(ds.appliedRoots.count, 1)
    }

    func testLayoutApplyRequiresRoot() {
        let (r, _) = router()
        guard case .error(let code, _) = r.handle(method: "layout.apply", params: [:]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.invalidParams)
    }

    func testLayoutApplyRejectedByDataSource() {
        let (r, ds) = router()
        ds.applyOk = false
        guard case .error = r.handle(method: "layout.apply", params: ["root": ["type": "pane"]]) else { return XCTFail() }
    }

    // MARK: - Explain

    func testExplainReturnsDetail() {
        let (r, ds) = router()
        ds.explains["t1"] = ["status": "waiting", "decided_by": "screen",
                             "matched_rule": ["id": "permission_prompt"]]
        guard case .ok(let d) = r.handle(method: "pane.explain", params: ["pane_id": "t1"]) else { return XCTFail() }
        XCTAssertEqual(d["status"] as? String, "waiting")
        XCTAssertEqual((d["matched_rule"] as? [String: Any])?["id"] as? String, "permission_prompt")
    }

    func testExplainAliasAndErrors() {
        let (r, ds) = router()
        ds.explains["t1"] = ["status": "idle"]
        guard case .ok = r.handle(method: "agent.explain", params: ["pane_id": "t1"]) else { return XCTFail() }
        guard case .error(let c1, _) = r.handle(method: "pane.explain", params: [:]) else { return XCTFail() }
        XCTAssertEqual(c1, ControlError.invalidParams)
        guard case .error(let c2, _) = r.handle(method: "pane.explain", params: ["pane_id": "nope"]) else { return XCTFail() }
        XCTAssertEqual(c2, ControlError.notFound)
    }

    // MARK: - Split

    func testSplitReturnsNewPaneId() {
        let (r, ds) = router()
        ds.splitResult = "p2"
        guard case .ok(let d) = r.handle(method: "pane.split",
                params: ["pane_id": "t1", "direction": "right", "focus": false]) else { return XCTFail() }
        XCTAssertEqual(d["pane_id"] as? String, "p2")
        XCTAssertEqual(ds.splitCalls.count, 1)
        XCTAssertEqual(ds.splitCalls[0].pane, "t1")
        XCTAssertEqual(ds.splitCalls[0].direction, "right")
        XCTAssertFalse(ds.splitCalls[0].focus)
    }

    func testSplitDefaultsRightAndFocus() {
        let (r, ds) = router()
        _ = r.handle(method: "pane.split", params: [:])
        XCTAssertNil(ds.splitCalls[0].pane)        // nil pane_id → focused
        XCTAssertEqual(ds.splitCalls[0].direction, "right")
        XCTAssertTrue(ds.splitCalls[0].focus)
    }

    func testSplitInvalidDirection() {
        let (r, _) = router()
        guard case .error(let code, _) = r.handle(method: "pane.split",
                params: ["direction": "sideways"]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.invalidParams)
    }

    func testSplitUnsplittable() {
        let (r, ds) = router()
        ds.splitResult = nil
        guard case .error(let code, _) = r.handle(method: "pane.split", params: [:]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.notFound)
    }

    func testCloseAndFocus() {
        let (r, ds) = router()
        guard case .ok(let c) = r.handle(method: "pane.close", params: ["pane_id": "t1"]) else { return XCTFail() }
        XCTAssertEqual(c["closed"] as? Bool, true)
        XCTAssertEqual(ds.closed, ["t1"])
        guard case .ok(let f) = r.handle(method: "pane.focus", params: ["pane_id": "t2"]) else { return XCTFail() }
        XCTAssertEqual(f["focused"] as? Bool, true)
        XCTAssertEqual(ds.focused, ["t2"])
    }

    func testCloseRequiresPaneId() {
        let (r, _) = router()
        guard case .error(let code, _) = r.handle(method: "pane.close", params: [:]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.invalidParams)
    }

    func testCloseNotFound() {
        let (r, ds) = router()
        ds.mutableOk = false
        guard case .error(let code, _) = r.handle(method: "pane.close", params: ["pane_id": "gone"]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.notFound)
    }

    // MARK: - Wait primitives

    func testWaitForOutputImmediateMatch() {
        let (r, ds) = router()
        ds.reads["t1"] = "build ok\nServer ready on :3000"
        guard case .ok(let d) = r.handle(method: "wait.output",
                params: ["pane_id": "t1", "match": "ready", "timeout_ms": 0]) else { return XCTFail() }
        XCTAssertEqual(d["matched"] as? Bool, true)
    }

    func testWaitForOutputTimeout() {
        let (r, ds) = router()
        ds.reads["t1"] = "nothing here"
        guard case .ok(let d) = r.handle(method: "wait.output",
                params: ["pane_id": "t1", "match": "ready", "timeout_ms": 0]) else { return XCTFail() }
        XCTAssertEqual(d["matched"] as? Bool, false)
        XCTAssertEqual(d["timed_out"] as? Bool, true)
    }

    func testWaitForOutputRegex() {
        let (r, ds) = router()
        ds.reads["t1"] = "listening on port 8080"
        guard case .ok(let d) = r.handle(method: "wait.output",
                params: ["pane_id": "t1", "match": "port [0-9]+", "regex": true, "timeout_ms": 0]) else { return XCTFail() }
        XCTAssertEqual(d["matched"] as? Bool, true)
    }

    func testWaitForOutputUnknownPane() {
        let (r, _) = router()
        guard case .error(let code, _) = r.handle(method: "wait.output",
                params: ["pane_id": "nope", "match": "x", "timeout_ms": 0]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.notFound)
    }

    func testWaitAgentStatusMatch() {
        let (r, ds) = router()
        ds.statuses["t1"] = "Waiting"
        guard case .ok(let d) = r.handle(method: "wait.agent_status",
                params: ["pane_id": "t1", "status": "waiting", "timeout_ms": 0]) else { return XCTFail() }
        XCTAssertEqual(d["matched"] as? Bool, true)
    }

    func testWaitAgentStatusDoneAliasesIdle() {
        let (r, ds) = router()
        ds.statuses["t1"] = "Idle"
        guard case .ok(let d) = r.handle(method: "wait.agent_status",
                params: ["pane_id": "t1", "status": "done", "timeout_ms": 0]) else { return XCTFail() }
        XCTAssertEqual(d["matched"] as? Bool, true)
    }

    func testControlKeysMapping() {
        XCTAssertEqual(ControlKeys.bytes(for: "esc"), "\u{1b}")
        XCTAssertEqual(ControlKeys.bytes(for: "ctrl+c"), "\u{03}")
        XCTAssertEqual(ControlKeys.bytes(for: "up"), "\u{1b}[A")
        XCTAssertNil(ControlKeys.bytes(for: "enter"))
        XCTAssertTrue(ControlKeys.isEnter("return"))
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
