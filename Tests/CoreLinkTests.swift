import XCTest
@testable import seahelm

/// The app follows seahelm-core for handles and for sessions the core started.
final class CoreLinkTests: XCTestCase {
    func testReadsHandlesAndSessionsTheAppHasNoPaneOn() {
        let rows: [[String: Any]] = [
            ["pane_session_key": "seahelm-repo-main", "worktree_path": "/r", "handle": 3],
            ["pane_session_key": "gpui-add-a-readme-1234", "worktree_path": "/r-wt/task/add-a-readme", "handle": 9],
            ["pane_session_key": "seahelm-first-mate", "worktree_path": "/fm"],
        ]
        let (handles, adoptable) = CoreLink.read(rows, appSessions: ["seahelm-repo-main"])
        XCTAssertEqual(handles, ["seahelm-repo-main": 3, "gpui-add-a-readme-1234": 9])
        XCTAssertEqual(adoptable["/r-wt/task/add-a-readme"], "gpui-add-a-readme-1234")
        XCTAssertNil(adoptable["/r"], "the app's own pane is not up for adoption")
    }

    func testTheCoresHandlesWin() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("handles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = PaneHandleRegistry(url: url)
        XCTAssertEqual(registry.handle(for: "a"), 1)
        XCTAssertEqual(registry.handle(for: "b"), 2)
        // The core numbered b as 1 and a as 7.
        registry.adopt(["b": 1, "a": 7])
        XCTAssertEqual(registry.existingHandle(for: "b"), 1)
        XCTAssertEqual(registry.existingHandle(for: "a"), 7)
        XCTAssertEqual(registry.handle(for: "c"), 8, "new panes start above every number in use")
        // Survives a relaunch.
        XCTAssertEqual(PaneHandleRegistry(url: url).existingHandle(for: "a"), 7)
    }
}
