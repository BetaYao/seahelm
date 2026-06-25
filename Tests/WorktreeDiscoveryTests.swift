import XCTest
@testable import seahelm

final class WorktreeDiscoveryTests: XCTestCase {

    // MARK: - Porcelain Parsing

    func testParseSingleWorktree() {
        let output = """
        worktree /Users/dev/project
        HEAD abc12345678
        branch refs/heads/main

        """
        let worktrees = WorktreeDiscovery.parsePorcelain(output)
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertEqual(worktrees[0].path, "/Users/dev/project")
        XCTAssertEqual(worktrees[0].branch, "main")
        XCTAssertEqual(worktrees[0].commitHash, "abc12345")
        XCTAssertTrue(worktrees[0].isMainWorktree)
    }

    func testParseMultipleWorktrees() {
        let output = """
        worktree /Users/dev/project
        HEAD abc1234567890
        branch refs/heads/main

        worktree /Users/dev/project-feature
        HEAD def4567890123
        branch refs/heads/feature-x

        worktree /Users/dev/project-fix
        HEAD 789abcdef012
        branch refs/heads/bugfix-y

        """
        let worktrees = WorktreeDiscovery.parsePorcelain(output)
        XCTAssertEqual(worktrees.count, 3)

        XCTAssertTrue(worktrees[0].isMainWorktree)
        XCTAssertEqual(worktrees[0].branch, "main")

        XCTAssertFalse(worktrees[1].isMainWorktree)
        XCTAssertEqual(worktrees[1].branch, "feature-x")
        XCTAssertEqual(worktrees[1].path, "/Users/dev/project-feature")

        XCTAssertFalse(worktrees[2].isMainWorktree)
        XCTAssertEqual(worktrees[2].branch, "bugfix-y")
    }

    func testParseDetachedHead() {
        let output = """
        worktree /Users/dev/project
        HEAD abc1234567890
        detached

        """
        let worktrees = WorktreeDiscovery.parsePorcelain(output)
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertEqual(worktrees[0].branch, "(detached)")
    }

    func testParseEmptyOutput() {
        let worktrees = WorktreeDiscovery.parsePorcelain("")
        XCTAssertTrue(worktrees.isEmpty)
    }

    func testParseNoTrailingNewline() {
        let output = """
        worktree /Users/dev/project
        HEAD abc1234567890
        branch refs/heads/main
        """
        let worktrees = WorktreeDiscovery.parsePorcelain(output)
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertEqual(worktrees[0].branch, "main")
    }

    // MARK: - Display Name

    func testDisplayName_MainWorktree() {
        let info = WorktreeInfo(path: "/Users/dev/project", branch: "main", commitHash: "abc", isMainWorktree: true)
        XCTAssertEqual(info.displayName, "project")
    }

    func testDisplayName_BranchWorktree() {
        let info = WorktreeInfo(path: "/Users/dev/project-feature", branch: "feature-x", commitHash: "abc", isMainWorktree: false)
        XCTAssertEqual(info.displayName, "feature-x")
    }

    func testDisplayName_NoBranch_FallsBackToPath() {
        let info = WorktreeInfo(path: "/Users/dev/project-feature", branch: "", commitHash: "abc", isMainWorktree: false)
        XCTAssertEqual(info.displayName, "project-feature")
    }
}
