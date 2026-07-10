import XCTest
@testable import seahelm

final class ManifestEngineTests: XCTestCase {

    private func manifest(_ json: String) throws -> CompiledManifest {
        let m = try JSONDecoder().decode(AgentManifest.self, from: Data(json.utf8))
        return CompiledManifest(try m.validated())
    }

    /// Regression: every bundled agent manifest must detect a braille-spinner OSC
    /// title as running. Previously only claude had this rule, so codex (and
    /// others) showed idle while "thinking" (spinner in title, static viewport).
    func testAllBundledManifestsDetectSpinnerTitle() {
        let store = ManifestStore.shared
        for id in ["claude", "codex", "opencode", "gemini", "cline", "goose",
                   "amp", "aider", "cursor", "kiro", "agent"] {
            guard let cm = store.manifest(for: id) else { XCTFail("missing \(id)"); continue }
            let d = cm.evaluate(DetectionInput(screen: "", oscTitle: "\u{2810} 调查查询服务不稳定的问题"))
            XCTAssertEqual(d.state, .running, "\(id) did not detect the spinner title as running")
            XCTAssertTrue(d.visibleWorking, "\(id) spinner should be visible_working")
        }
    }

    /// Regression: Claude Code at an idle prompt but with background tasks still
    /// running (footer shows "· 1 shell ·" / "← 2 agents", or the transcript
    /// spinner line ends with "1 shell still running") must detect as running,
    /// not fall through to the idle default.
    func testClaudeBackgroundTasksDetectAsRunning() {
        guard let cm = ManifestStore.shared.manifest(for: "claude") else {
            return XCTFail("missing claude manifest")
        }
        let footers = [
            "some transcript text\n\n❯ \n▸▸ bypass permissions on · 1 shell · ← 2 agents",
            "some transcript text\n\n❯ \n▸▸ bypass permissions on · 2 shells",
            "* sautéed for 2m 10s · 1 shell still running\n\n❯ \ncontext 6%",
        ]
        for screen in footers {
            let d = cm.evaluate(DetectionInput(screen: screen.lowercased()))
            XCTAssertEqual(d.state, .running, "expected running for: \(screen)")
            XCTAssertTrue(d.visibleWorking)
        }
        // Idle prompts must NOT match: "← 2 agents" is a persistent connected-
        // agents indicator (not a background task), and transcript prose like
        // "ran 2 shell commands" above the prompt is not a footer signal.
        let idles = [
            "ran 2 shell commands\ndone.\n\n❯ \n▸▸ bypass permissions on",
            "done.\n\n❯ \n▸▸ bypass permissions on (shift+tab to cycle) · ← 2 agents",
        ]
        for screen in idles {
            XCTAssertEqual(cm.evaluate(DetectionInput(screen: screen)).state, .unknown,
                           "expected no match for: \(screen)")
        }
    }

    func testHighestPriorityWins() throws {
        // Two rules match; the higher-priority (waiting) must win over running.
        let cm = try manifest("""
        { "id": "t", "default_status": "idle", "rules": [
          { "id": "run", "state": "running", "priority": 100, "region": "whole_recent", "contains": ["to interrupt"] },
          { "id": "wait", "state": "waiting", "priority": 900, "region": "whole_recent", "contains": ["(y/n)"] }
        ]}
        """)
        let d = cm.evaluate(DetectionInput(screen: "esc to interrupt ... proceed? (y/n)"))
        XCTAssertEqual(d.state, .waiting)
        XCTAssertEqual(d.matchedRuleId, "wait")
    }

    func testNoMatchReturnsUnknownThenDefault() throws {
        let cm = try manifest("""
        { "id": "t", "default_status": "idle", "rules": [
          { "id": "run", "state": "running", "priority": 100, "region": "whole_recent", "contains": ["to interrupt"] }
        ]}
        """)
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: "nothing here")).state, .unknown)
        XCTAssertEqual(cm.defaultStatus, .idle)
    }

    func testAnyGate() throws {
        let cm = try manifest("""
        { "id": "t", "default_status": "idle", "rules": [
          { "id": "perm", "state": "waiting", "priority": 500, "region": "whole_recent",
            "any": [ { "contains": ["yes, proceed"] }, { "contains": ["(yes/no)"] } ] }
        ]}
        """)
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: "1. yes, proceed")).state, .waiting)
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: "run this? (yes/no)")).state, .waiting)
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: "unrelated")).state, .unknown)
    }

    func testNotGateBlocks() throws {
        let cm = try manifest("""
        { "id": "t", "default_status": "idle", "rules": [
          { "id": "run", "state": "running", "priority": 500, "region": "whole_recent",
            "contains": ["working"], "not": [ { "contains": ["done"] } ] }
        ]}
        """)
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: "working hard")).state, .running)
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: "working done")).state, .unknown)
    }

    func testRegionBottomLinesIgnoresOldOutput() throws {
        // "error:" is far above; bottom_lines:2 must not see it.
        let cm = try manifest("""
        { "id": "t", "default_status": "idle", "rules": [
          { "id": "err", "state": "error", "priority": 700, "region": "bottom_lines:2", "contains": ["error:"] }
        ]}
        """)
        let screen = "error: old failure\nline1\nline2\nline3"
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: screen)).state, .unknown)
        let screen2 = "ok\nerror: fresh"
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: screen2)).state, .error)
    }

    func testOscTitleRegion() throws {
        let cm = try manifest("""
        { "id": "t", "default_status": "idle", "rules": [
          { "id": "spin", "state": "running", "priority": 1100, "region": "osc_title",
            "regex": ["^[\\\\x{2800}-\\\\x{28FF}] "], "visible_working": true }
        ]}
        """)
        let d = cm.evaluate(DetectionInput(screen: "", oscTitle: "\u{2807} Working…"))
        XCTAssertEqual(d.state, .running)
        XCTAssertTrue(d.visibleWorking)
    }

    func testSkipStateUpdateFlagCarried() throws {
        let cm = try manifest("""
        { "id": "t", "default_status": "idle", "rules": [
          { "id": "viewer", "state": "idle", "priority": 300, "region": "whole_recent",
            "contains": ["show transcript"], "skip_state_update": true }
        ]}
        """)
        let d = cm.evaluate(DetectionInput(screen: "show transcript"))
        XCTAssertTrue(d.skipStateUpdate)
        XCTAssertEqual(d.matchedRuleId, "viewer")
    }

    func testEngineVersionGuardRejects() throws {
        let m = try JSONDecoder().decode(AgentManifest.self, from: Data("""
        { "id": "t", "min_engine_version": 999, "rules": [] }
        """.utf8))
        XCTAssertThrowsError(try m.validated())
    }

    func testStatusMapping() {
        XCTAssertEqual(SailorStatus.fromManifest("working"), .running)
        XCTAssertEqual(SailorStatus.fromManifest("blocked"), .waiting)
        XCTAssertEqual(SailorStatus.fromManifest("IDLE"), .idle)
    }
}
