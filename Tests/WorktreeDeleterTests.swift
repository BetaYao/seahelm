import XCTest
@testable import seahelm

/// Functional tests for WorktreeDeleter using real git repos in temp directories.
final class WorktreeDeleterTests: XCTestCase {

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

    // MARK: - hasUncommittedChanges

    func testCleanRepoHasNoChanges() {
        XCTAssertFalse(WorktreeDeleter.hasUncommittedChanges(worktreePath: repoPath))
    }

    func testDirtyRepoHasChanges() {
        // Create an untracked file
        let filePath = tempDir.appendingPathComponent("repo/dirty.txt").path
        FileManager.default.createFile(atPath: filePath, contents: "dirty".data(using: .utf8))
        XCTAssertTrue(WorktreeDeleter.hasUncommittedChanges(worktreePath: repoPath))
    }

    func testModifiedFileDetected() {
        // Modify tracked file
        let filePath = tempDir.appendingPathComponent("repo/initial.txt").path
        try? "modified content".write(toFile: filePath, atomically: true, encoding: .utf8)
        XCTAssertTrue(WorktreeDeleter.hasUncommittedChanges(worktreePath: repoPath))
    }

    // MARK: - deleteWorktree

    func testDeleteWorktreeRemovesDirectory() throws {
        let worktreePath = createWorktree(branch: "feature-delete-test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath))

        try WorktreeDeleter.deleteWorktree(
            worktreePath: worktreePath,
            repoPath: repoPath,
            branchName: "feature-delete-test",
            deleteBranch: false,
            force: false
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
    }

    func testDeleteWorktreeWithBranchDeletesBranch() throws {
        let worktreePath = createWorktree(branch: "feature-branch-delete")

        try WorktreeDeleter.deleteWorktree(
            worktreePath: worktreePath,
            repoPath: repoPath,
            branchName: "feature-branch-delete",
            deleteBranch: true,
            force: false
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
        // Branch should be gone
        let branches = git(["branch", "--list", "feature-branch-delete"], in: repoPath)
        XCTAssertTrue(branches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testDeleteWorktreeWithoutBranchKeepsBranch() throws {
        let worktreePath = createWorktree(branch: "feature-keep-branch")

        try WorktreeDeleter.deleteWorktree(
            worktreePath: worktreePath,
            repoPath: repoPath,
            branchName: "feature-keep-branch",
            deleteBranch: false,
            force: false
        )

        // Directory gone, branch still exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
        let branches = git(["branch", "--list", "feature-keep-branch"], in: repoPath)
        XCTAssertFalse(branches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testDeleteMainWorktreeThrows() {
        XCTAssertThrowsError(
            try WorktreeDeleter.deleteWorktree(
                worktreePath: repoPath,
                repoPath: repoPath,
                branchName: "main",
                deleteBranch: false,
                force: false
            )
        ) { error in
            // Either our guard catches it (isMainWorktree) or git itself rejects it (gitFailed with "main working tree")
            guard let delError = error as? WorktreeDeleterError else {
                XCTFail("Expected WorktreeDeleterError, got \(error)")
                return
            }
            switch delError {
            case .isMainWorktree:
                break // Expected
            case .gitFailed(let msg) where msg.contains("main working tree"):
                break // Also acceptable — git caught it
            default:
                XCTFail("Unexpected error: \(delError)")
            }
        }
    }

    func testDeleteDirtyWorktreeWithoutForceThrows() {
        let worktreePath = createWorktree(branch: "feature-dirty")
        // Make it dirty
        let filePath = URL(fileURLWithPath: worktreePath).appendingPathComponent("dirty.txt").path
        FileManager.default.createFile(atPath: filePath, contents: "dirty".data(using: .utf8))
        git(["add", "dirty.txt"], in: worktreePath)
        git(["commit", "-m", "add dirty file"], in: worktreePath)
        // Modify after commit to make it "dirty" from worktree perspective
        try? "modified".write(toFile: filePath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try WorktreeDeleter.deleteWorktree(
                worktreePath: worktreePath,
                repoPath: repoPath,
                branchName: "feature-dirty",
                deleteBranch: false,
                force: false
            )
        )
    }

    func testDeleteDirtyWorktreeWithForceSucceeds() throws {
        let worktreePath = createWorktree(branch: "feature-force")
        // Make it dirty
        let filePath = URL(fileURLWithPath: worktreePath).appendingPathComponent("dirty.txt").path
        try "dirty".write(toFile: filePath, atomically: true, encoding: .utf8)

        try WorktreeDeleter.deleteWorktree(
            worktreePath: worktreePath,
            repoPath: repoPath,
            branchName: "feature-force",
            deleteBranch: false,
            force: true
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
    }

    // MARK: - merge check

    func testMergedWorktreeCanBeCleanedWhenHeadIsInOriginMain() throws {
        let worktreePath = createWorktree(branch: "feature-merged")
        let filePath = URL(fileURLWithPath: worktreePath).appendingPathComponent("merged.txt").path
        try "merged".write(toFile: filePath, atomically: true, encoding: .utf8)
        git(["add", "merged.txt"], in: worktreePath)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test", "commit", "-m", "merged work"], in: worktreePath)
        git(["merge", "--ff-only", "feature-merged"], in: repoPath)
        git(["update-ref", "refs/remotes/origin/main", "main"], in: repoPath)

        let check = WorktreeDeleter.mergeCheckForOnlineMainOrMaster(worktreePath: worktreePath, repoPath: repoPath)

        XCTAssertTrue(check.canDelete, check.reason)
        XCTAssertEqual(check.targetBranch, "origin/main")
    }

    func testUnmergedWorktreeCannotBeCleaned() throws {
        git(["update-ref", "refs/remotes/origin/main", "main"], in: repoPath)
        let worktreePath = createWorktree(branch: "feature-unmerged")
        let filePath = URL(fileURLWithPath: worktreePath).appendingPathComponent("unmerged.txt").path
        try "unmerged".write(toFile: filePath, atomically: true, encoding: .utf8)
        git(["add", "unmerged.txt"], in: worktreePath)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test", "commit", "-m", "unmerged work"], in: worktreePath)

        let check = WorktreeDeleter.mergeCheckForOnlineMainOrMaster(worktreePath: worktreePath, repoPath: repoPath)

        XCTAssertFalse(check.canDelete)
        XCTAssertEqual(check.targetBranch, "origin/main")
    }

    func testCleanMergedWorktreesScansAllLinkedWorktrees() throws {
        let mergedPath = createWorktree(branch: "feature-global-merged")
        let mergedFile = URL(fileURLWithPath: mergedPath).appendingPathComponent("global-merged.txt").path
        try "merged".write(toFile: mergedFile, atomically: true, encoding: .utf8)
        git(["add", "global-merged.txt"], in: mergedPath)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test", "commit", "-m", "global merged"], in: mergedPath)
        git(["merge", "--ff-only", "feature-global-merged"], in: repoPath)
        git(["update-ref", "refs/remotes/origin/main", "main"], in: repoPath)

        let unmergedPath = createWorktree(branch: "feature-global-unmerged")
        let unmergedFile = URL(fileURLWithPath: unmergedPath).appendingPathComponent("global-unmerged.txt").path
        try "unmerged".write(toFile: unmergedFile, atomically: true, encoding: .utf8)
        git(["add", "global-unmerged.txt"], in: unmergedPath)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test", "commit", "-m", "global unmerged"], in: unmergedPath)

        let worktrees = WorktreeDiscovery.discover(repoPath: repoPath)
        let summary = WorktreeDeleter.cleanMergedWorktrees(
            worktrees: worktrees,
            repoPathForWorktree: { _ in repoPath }
        )

        XCTAssertEqual(summary.deletedPaths.map(lastPathComponent), ["feature-global-merged"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mergedPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmergedPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoPath))
    }

    // MARK: - Helpers

    private func createTestRepo() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        git(["init", "-b", "main"], in: repoPath)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test", "commit", "--allow-empty", "-m", "Initial commit"], in: repoPath)
        // Create a tracked file
        let filePath = tempDir.appendingPathComponent("repo/initial.txt").path
        fm.createFile(atPath: filePath, contents: "initial".data(using: .utf8))
        git(["add", "initial.txt"], in: repoPath)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test", "commit", "-m", "Add initial file"], in: repoPath)
    }

    @discardableResult
    private func createWorktree(branch: String) -> String {
        let worktreePath = tempDir.appendingPathComponent("worktrees/\(branch)").path
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: worktreePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        git(["worktree", "add", "-b", branch, worktreePath, "main"], in: repoPath)
        return worktreePath
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

    private func lastPathComponent(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
