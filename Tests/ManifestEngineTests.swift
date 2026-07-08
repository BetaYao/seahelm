import XCTest
@testable import seahelm

final class ManifestEngineTests: XCTestCase {

    private func manifest(_ json: String) throws -> CompiledManifest {
        let m = try JSONDecoder().decode(AgentManifest.self, from: Data(json.utf8))
        return CompiledManifest(try m.validated())
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
