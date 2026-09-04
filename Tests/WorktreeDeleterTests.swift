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
            case .gitFailed(let msg) where msg.contains("main worktree"):
                // Fallback only. This used to match git's raw "is a main working
                // tree", which classifyWorktreeRemoveError had already rewritten,
                // so the case never fired and the guard's symlink bug hid behind
                // an "Unexpected error" instead of being reported as one.
                XCTFail("guard should have caught this before git: \(msg)")
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

    // MARK: - delete assessment

    /// Nothing of its own: clean, and every commit already on trunk. That is
    /// the case that must not get a sheet.
    func testAssessmentIsSafeForACleanMergedWorktree() throws {
        let worktreePath = createWorktree(branch: "feature-safe")
        try commitFile("safe.txt", in: worktreePath)
        git(["merge", "--ff-only", "feature-safe"], in: repoPath)
        git(["update-ref", "refs/remotes/origin/main", "main"], in: repoPath)

        let assessment = WorktreeDeleter.assessDeletion(
            worktreePath: worktreePath, repoPath: repoPath, branchName: "feature-safe", recordedBase: nil)

        XCTAssertTrue(assessment.isSafe, assessment.losses.joined(separator: " / "))
        XCTAssertTrue(assessment.deletesBranch)
    }

    func testAssessmentCountsCommitsThatAreNowhereElse() throws {
        git(["update-ref", "refs/remotes/origin/main", "main"], in: repoPath)
        let worktreePath = createWorktree(branch: "feature-unpublished")
        try commitFile("one.txt", in: worktreePath)
        try commitFile("two.txt", in: worktreePath)

        let assessment = WorktreeDeleter.assessDeletion(
            worktreePath: worktreePath, repoPath: repoPath, branchName: "feature-unpublished", recordedBase: nil)

        XCTAssertFalse(assessment.isSafe)
        XCTAssertTrue(assessment.deletesBranch)
        XCTAssertEqual(assessment.losses.count, 1)
        XCTAssertTrue(assessment.losses[0].contains("2 commits not in origin/main"), assessment.losses[0])
        XCTAssertTrue(assessment.losses[0].contains("branch will be deleted"), assessment.losses[0])
    }

    func testAssessmentNamesUncommittedChanges() throws {
        git(["update-ref", "refs/remotes/origin/main", "main"], in: repoPath)
        let worktreePath = createWorktree(branch: "feature-dirty")
        try "wip".write(toFile: worktreePath + "/wip.txt", atomically: true, encoding: .utf8)

        let assessment = WorktreeDeleter.assessDeletion(
            worktreePath: worktreePath, repoPath: repoPath, branchName: "feature-dirty", recordedBase: nil)

        XCTAssertEqual(assessment.losses, ["It has uncommitted changes that will be lost."])
    }

    /// Pushed but unmerged: the remote still has every commit, so deleting
    /// the local branch loses nothing.
    func testAssessmentTreatsAFullyPushedBranchAsSafe() throws {
        git(["update-ref", "refs/remotes/origin/main", "main"], in: repoPath)
        let worktreePath = createWorktree(branch: "feature-pushed")
        try commitFile("pushed.txt", in: worktreePath)
        // `@{upstream}` needs the remote's fetch refspec to map the branch to
        // its tracking ref; the URL is never contacted.
        git(["remote", "add", "origin", repoPath], in: repoPath)
        git(["update-ref", "refs/remotes/origin/feature-pushed", "feature-pushed"], in: repoPath)
        git(["config", "branch.feature-pushed.remote", "origin"], in: repoPath)
        git(["config", "branch.feature-pushed.merge", "refs/heads/feature-pushed"], in: repoPath)

        let assessment = WorktreeDeleter.assessDeletion(
            worktreePath: worktreePath, repoPath: repoPath, branchName: "feature-pushed", recordedBase: nil)

        XCTAssertTrue(assessment.isSafe, assessment.losses.joined(separator: " / "))
    }

    /// A rebase rewrites hashes but not patches. The branch is merged in every
    /// sense that matters, and must read that way.
    func testAssessmentSeesARebasedBranchAsMerged() throws {
        let worktreePath = createWorktree(branch: "feature-rebased")
        try commitFile("rebased.txt", in: worktreePath)
        // Land the same patch on main under a different hash.
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test", "cherry-pick", "feature-rebased"], in: repoPath)
        git(["update-ref", "refs/remotes/origin/main", "main"], in: repoPath)

        let assessment = WorktreeDeleter.assessDeletion(
            worktreePath: worktreePath, repoPath: repoPath, branchName: "feature-rebased", recordedBase: nil)

        XCTAssertTrue(assessment.isSafe, assessment.losses.joined(separator: " / "))
    }

    /// A worktree checked out on trunk is removable; trunk is not.
    func testAssessmentKeepsATrunkBranch() throws {
        git(["checkout", "-b", "elsewhere"], in: repoPath)
        let worktreePath = tempDir.appendingPathComponent("worktrees/on-main").path
        git(["worktree", "add", worktreePath, "main"], in: repoPath)

        let assessment = WorktreeDeleter.assessDeletion(
            worktreePath: worktreePath, repoPath: repoPath, branchName: "main", recordedBase: nil)

        XCTAssertTrue(assessment.isSafe, assessment.losses.joined(separator: " / "))
        XCTAssertFalse(assessment.deletesBranch)
    }

    func testAssessmentOfADetachedWorktreeDeletesNoBranch() throws {
        let worktreePath = tempDir.appendingPathComponent("worktrees/detached").path
        git(["worktree", "add", "--detach", worktreePath, "main"], in: repoPath)

        let assessment = WorktreeDeleter.assessDeletion(
            worktreePath: worktreePath, repoPath: repoPath, branchName: "", recordedBase: nil)

        XCTAssertTrue(assessment.isSafe, assessment.losses.joined(separator: " / "))
        XCTAssertFalse(assessment.deletesBranch)
    }

    /// The assessment already established the commits are on trunk, so the
    /// branch must go even where git's own `-d` check (upstream only) would
    /// refuse: merged through a PR with an unpushed commit still on it.
    func testForcedBranchDeleteIgnoresAStaleUpstream() throws {
        let worktreePath = createWorktree(branch: "feature-stale-upstream")
        git(["update-ref", "refs/remotes/origin/feature-stale-upstream", "feature-stale-upstream"], in: repoPath)
        git(["config", "branch.feature-stale-upstream.remote", "origin"], in: repoPath)
        git(["config", "branch.feature-stale-upstream.merge", "refs/heads/feature-stale-upstream"], in: repoPath)
        try commitFile("late.txt", in: worktreePath)
        git(["merge", "--ff-only", "feature-stale-upstream"], in: repoPath)

        let result = try WorktreeDeleter.deleteWorktree(
            worktreePath: worktreePath, repoPath: repoPath, branchName: "feature-stale-upstream",
            deleteBranch: true, force: false, forceBranch: true)

        XCTAssertNil(result.branchWarning)
        XCTAssertFalse(git(["branch", "--list", "feature-stale-upstream"], in: repoPath).contains("feature-stale-upstream"))
    }

    private func commitFile(_ name: String, in worktreePath: String) throws {
        try name.write(toFile: worktreePath + "/" + name, atomically: true, encoding: .utf8)
        git(["add", name], in: worktreePath)
        git(["-c", "user.email=test@test.com", "-c", "user.name=Test", "commit", "-m", "add \(name)"], in: worktreePath)
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

    /// The guard compared path strings, so any caller holding a path that
    /// reaches the repo through a symlink — every macOS temp dir, since /var is
    /// /private/var — slipped past it and was caught by git instead.
    func testSamePathResolvesSymlinks() {
        // Real directories on purpose: resolvingSymlinksInPath leaves a path
        // that does not exist untouched, so a fabricated /var vs /private/var
        // pair would test nothing and pass for the wrong reason.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("samepath-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let viaSymlink = dir.path                    // /var/folders/...
        let real = "/private" + dir.path             // /private/var/folders/...
        XCTAssertTrue(FileManager.default.fileExists(atPath: real), "precondition: /var is /private/var")
        XCTAssertTrue(WorktreeDeleter.samePath(viaSymlink, real),
                      "git reports the real path; a caller may hold the symlinked one")
        XCTAssertTrue(WorktreeDeleter.samePath(viaSymlink, viaSymlink))
        XCTAssertFalse(WorktreeDeleter.samePath(viaSymlink, dir.deletingLastPathComponent().path))
    }
}
