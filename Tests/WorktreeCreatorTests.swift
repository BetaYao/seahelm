import XCTest
@testable import seahelm

/// Functional tests for WorktreeCreator using real git repos.
final class WorktreeCreatorTests: XCTestCase {

    private var tempDir: URL!
    private var repoPath: String!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        repoPath = tempDir.appendingPathComponent("repo").path
        createTestRepo()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - listBranches

    func testListBranchesIncludesMain() {
        let branches = WorktreeCreator.listBranches(repoPath: repoPath)
        XCTAssertTrue(branches.contains("main"), "Should include main branch, got: \(branches)")
    }

    func testListBranchesNoDuplicates() {
        let branches = WorktreeCreator.listBranches(repoPath: repoPath)
        let unique = Set(branches)
        XCTAssertEqual(branches.count, unique.count, "Should have no duplicate branches")
    }

    // MARK: - createWorktree

    func testCreateWorktreeSuccess() throws {
        let info = try WorktreeCreator.createWorktree(
            repoPath: repoPath,
            branchName: "feature-new",
            baseBranch: "main"
        )

        XCTAssertEqual(info.branch, "feature-new")
        XCTAssertFalse(info.isMainWorktree)
        XCTAssertFalse(info.commitHash.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.path))
    }

    func testCreateWorktreeDirectoryStructure() throws {
        let info = try WorktreeCreator.createWorktree(
            repoPath: repoPath,
            branchName: "feature-structure",
            baseBranch: "main"
        )

        // Should be in <repo>-worktrees/<branch>/
        XCTAssertTrue(info.path.contains("repo-worktrees/feature-structure"))
    }

    func testCreateWorktreeHasCorrectContent() throws {
        let info = try WorktreeCreator.createWorktree(
            repoPath: repoPath,
            branchName: "feature-content",
            baseBranch: "main"
        )

        // Should have the initial file from main
        let filePath = URL(fileURLWithPath: info.path).appendingPathComponent("initial.txt").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath))
    }

    func testBranchNameFromTaskDescriptionCreatesReadableSlug() {
        let branch = WorktreeCreator.branchName(fromTaskDescription: "Fix flaky login redirect!!!")

        XCTAssertEqual(branch, "task/fix-flaky-login-redirect")
    }

    func testBranchNameFromChineseTaskDescriptionIsGitSafe() {
        let branch = WorktreeCreator.branchName(fromTaskDescription: "修复工作树卡片聚焦")

        XCTAssertTrue(branch.hasPrefix("task/"))
        XCTAssertFalse(branch.contains(" "))
        XCTAssertFalse(branch.contains("修"))
        XCTAssertGreaterThan(branch.count, "task/".count)
    }

    func testBranchNameFromTaskDescriptionAvoidsExistingBranches() {
        let branch = WorktreeCreator.branchName(
            fromTaskDescription: "Fix flaky login redirect",
            existingBranches: ["main", "task/fix-flaky-login-redirect", "task/fix-flaky-login-redirect-2"]
        )

        XCTAssertEqual(branch, "task/fix-flaky-login-redirect-3")
    }

    func testCreateWorktreeDuplicatePathThrows() throws {
        // Create first worktree
        _ = try WorktreeCreator.createWorktree(
            repoPath: repoPath,
            branchName: "feature-dup",
            baseBranch: "main"
        )

        // Creating same branch again should fail (path exists)
        XCTAssertThrowsError(
            try WorktreeCreator.createWorktree(
                repoPath: repoPath,
                branchName: "feature-dup",
                baseBranch: "main"
            )
        )
    }

    // MARK: - Full Lifecycle: Create → Verify → Delete

    func testWorktreeFullLifecycle() throws {
        // Create
        let info = try WorktreeCreator.createWorktree(
            repoPath: repoPath,
            branchName: "lifecycle-test",
            baseBranch: "main"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.path))

        // Verify worktree shows up in git worktree list
        let worktrees = WorktreeDiscovery.discover(repoPath: repoPath)
        XCTAssertTrue(worktrees.contains(where: { $0.branch == "lifecycle-test" }))

        // Delete
        try WorktreeDeleter.deleteWorktree(
            worktreePath: info.path,
            repoPath: repoPath,
            branchName: "lifecycle-test",
            deleteBranch: true,
            force: false
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: info.path))

        // Verify worktree no longer shows up
        let after = WorktreeDiscovery.discover(repoPath: repoPath)
        XCTAssertFalse(after.contains(where: { $0.branch == "lifecycle-test" }))
    }

    // MARK: - Helpers

    private func createTestRepo() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoPath)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test", "commit", "--allow-empty", "-m", "Initial commit"], in: repoPath)
        let filePath = tempDir.appendingPathComponent("repo/initial.txt").path
        fm.createFile(atPath: filePath, contents: "initial content".data(using: .utf8))
        git(["add", "initial.txt"], in: repoPath)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test", "commit", "-m", "Add initial file"], in: repoPath)
    }

    @discardableResult
    private func git(_ args: [String], in directory: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
