import XCTest
@testable import seahelm

final class WorkspaceManagerTests: XCTestCase {
    var manager: WorkspaceManager!

    override func setUp() {
        manager = WorkspaceManager()
    }

    // MARK: - Add Tab

    func testAddTab() {
        let index = manager.addTab(repoPath: "/path/to/repo", worktrees: [])
        XCTAssertEqual(index, 0)
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.tabs[0].displayName, "repo")
    }

    func testAddTab_NoDuplicates() {
        let idx1 = manager.addTab(repoPath: "/path/to/repo", worktrees: [])
        let idx2 = manager.addTab(repoPath: "/path/to/repo", worktrees: [])
        XCTAssertEqual(idx1, idx2)
        XCTAssertEqual(manager.tabs.count, 1)
    }

    func testAddTab_MultipleDifferent() {
        manager.addTab(repoPath: "/path/to/repo-a", worktrees: [])
        manager.addTab(repoPath: "/path/to/repo-b", worktrees: [])
        XCTAssertEqual(manager.tabs.count, 2)
    }

    // MARK: - Remove Tab

    func testRemoveTab() {
        manager.addTab(repoPath: "/path/to/repo-a", worktrees: [])
        manager.addTab(repoPath: "/path/to/repo-b", worktrees: [])
        manager.removeTab(at: 0)
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.tabs[0].repoPath, "/path/to/repo-b")
    }

    func testRemoveTab_InvalidIndex() {
        manager.addTab(repoPath: "/path/to/repo", worktrees: [])
        manager.removeTab(at: 5)  // out of bounds
        XCTAssertEqual(manager.tabs.count, 1)
    }

    // MARK: - Tab Lookup

    func testTabAt() {
        manager.addTab(repoPath: "/path/to/repo", worktrees: [])
        XCTAssertNotNil(manager.tab(at: 0))
        XCTAssertNil(manager.tab(at: 1))
    }

    // MARK: - Name Disambiguation

    func testDisambiguateNames_SameName() {
        manager.addTab(repoPath: "/org-a/workspace/myapp", worktrees: [])
        manager.addTab(repoPath: "/org-b/workspace/myapp", worktrees: [])
        // Both have last component "myapp", so should include parent
        XCTAssertEqual(manager.tabs[0].displayName, "workspace/myapp")
        XCTAssertEqual(manager.tabs[1].displayName, "workspace/myapp")
    }

    func testDisambiguateNames_DifferentParent() {
        manager.addTab(repoPath: "/org-a/repos/myapp", worktrees: [])
        manager.addTab(repoPath: "/org-b/projects/myapp", worktrees: [])
        XCTAssertEqual(manager.tabs[0].displayName, "repos/myapp")
        XCTAssertEqual(manager.tabs[1].displayName, "projects/myapp")
    }

    func testDisambiguateNames_UniqueName() {
        manager.addTab(repoPath: "/path/to/alpha", worktrees: [])
        manager.addTab(repoPath: "/path/to/beta", worktrees: [])
        // Different last components, no disambiguation needed
        XCTAssertEqual(manager.tabs[0].displayName, "alpha")
        XCTAssertEqual(manager.tabs[1].displayName, "beta")
    }

    func testDisambiguateNames_AfterRemoval() {
        manager.addTab(repoPath: "/org-a/workspace/myapp", worktrees: [])
        manager.addTab(repoPath: "/org-b/workspace/myapp", worktrees: [])
        // Both disambiguated
        XCTAssertTrue(manager.tabs[0].displayName.contains("/"))

        // Remove one, the other should simplify
        manager.removeTab(at: 1)
        XCTAssertEqual(manager.tabs[0].displayName, "myapp")
    }
}
