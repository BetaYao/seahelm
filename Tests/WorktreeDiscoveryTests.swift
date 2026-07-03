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

    // MARK: - findRepoRoot (real git repos in a temp dir)

    /// A linked worktree must resolve to the MAIN repo root, not its own path —
    /// `--show-toplevel` got this wrong and let deleted worktrees pollute
    /// workspace_paths as phantom repos.
    func testFindRepoRoot_LinkedWorktreeResolvesToMainRepo() throws {
        let base = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }

        let worktreePath = base.deletingLastPathComponent().appendingPathComponent("wt-feature").path
        try runGit(["worktree", "add", worktreePath, "-b", "feature"], in: base.path)

        let canonicalBase = WorktreeDiscovery.canonicalPath(base.path)
        XCTAssertEqual(WorktreeDiscovery.findRepoRoot(from: worktreePath).map(WorktreeDiscovery.canonicalPath),
                       canonicalBase)
        // Main repo root and a subdirectory of it resolve to the root as well.
        XCTAssertEqual(WorktreeDiscovery.findRepoRoot(from: base.path).map(WorktreeDiscovery.canonicalPath),
                       canonicalBase)
        let subdir = base.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        XCTAssertEqual(WorktreeDiscovery.findRepoRoot(from: subdir.path).map(WorktreeDiscovery.canonicalPath),
                       canonicalBase)
    }

    func testFindRepoRoot_NonexistentPathReturnsNil() {
        XCTAssertNil(WorktreeDiscovery.findRepoRoot(from: "/nonexistent/path/for/seahelm/tests"))
    }

    private func makeTempGitRepo() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seahelm-discovery-\(UUID().uuidString)")
            .appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-q"], in: dir.path)
        try runGit(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init", "-q"], in: dir.path)
        return dir
    }

    private func runGit(_ args: [String], in dir: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
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
