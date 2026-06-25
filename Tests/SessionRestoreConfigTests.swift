import XCTest
@testable import seahelm

final class SessionRestoreConfigTests: XCTestCase {
    func testSessionFieldsDecodeFromJSON() throws {
        let json = """
        {
            "active_tab_repo_path": "/repos/myproject",
            "active_worktree_paths": {"/repos/myproject": "/repos/myproject/wt-feat"},
            "focused_pane_ids": {"/repos/myproject/wt-feat": "leaf-abc"}
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(config.activeTabRepoPath, "/repos/myproject")
        XCTAssertEqual(config.activeWorktreePaths["/repos/myproject"], "/repos/myproject/wt-feat")
        XCTAssertEqual(config.focusedPaneIds["/repos/myproject/wt-feat"], "leaf-abc")
    }

    func testSessionFieldsDefaultToEmpty() throws {
        let json = "{}".data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertNil(config.activeTabRepoPath)
        XCTAssertTrue(config.activeWorktreePaths.isEmpty)
        XCTAssertTrue(config.focusedPaneIds.isEmpty)
    }

    func testSessionFieldsRoundTrip() throws {
        var config = Config()
        config.activeTabRepoPath = "/repos/proj"
        config.activeWorktreePaths = ["/repos/proj": "/repos/proj/wt-1"]
        config.focusedPaneIds = ["/repos/proj/wt-1": "leaf-xyz"]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded.activeTabRepoPath, "/repos/proj")
        XCTAssertEqual(decoded.activeWorktreePaths, config.activeWorktreePaths)
        XCTAssertEqual(decoded.focusedPaneIds, config.focusedPaneIds)
    }
}
