import XCTest
@testable import seahelm

final class UnattendedDeleteTests: XCTestCase {
    func testVerdicts() {
        XCTAssertEqual(WorktreeDeleteAssessment(losses: [], deletesBranch: true).unattendedVerdict.allowed, true)
        let dirty = WorktreeDeleteAssessment(losses: [WorktreeDeleteAssessment.uncommittedLoss], deletesBranch: true)
        XCTAssertTrue(dirty.unattendedVerdict.allowed, "the card showed the uncommitted files")
        XCTAssertTrue(dirty.unattendedVerdict.force)
        let commits = WorktreeDeleteAssessment(losses: [WorktreeDeleteAssessment.uncommittedLoss,
                                                        "Branch “x” has 2 commits not in main and not pushed."],
                                               deletesBranch: true)
        XCTAssertFalse(commits.unattendedVerdict.allowed, "commits are never thrown away unattended")
        XCTAssertTrue(commits.unattendedVerdict.refusal?.contains("2 commits") == true)
    }

    /// End to end on a real repo: a dirty worktree whose commits are all on trunk
    /// is removed (force), one with an unpushed commit is refused and kept.
    func testDirtyIsDeletedButUnpushedWorkIsKept() throws {
        let root = NSTemporaryDirectory() + "unattended-\(UUID().uuidString)"
        let repo = root + "/repo"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ args: String..., in dir: String) { _ = GitProcess.run(args, in: dir, timeout: 30) }
        git("init", "-q", "-b", "main", in: repo)
        git("config", "user.email", "t@t", in: repo); git("config", "user.name", "t", in: repo)
        try "a\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        git("add", ".", in: repo); git("commit", "-qm", "one", in: repo)

        let dirtyWT = root + "/wt-dirty"
        git("worktree", "add", "-q", "-b", "dirty", dirtyWT, in: repo)
        try "changed\n".write(toFile: dirtyWT + "/a.txt", atomically: true, encoding: .utf8)
        let dirty = WorktreeDeleter.assessDeletion(worktreePath: dirtyWT, repoPath: repo, branchName: "dirty")
        XCTAssertEqual(dirty.losses, [WorktreeDeleteAssessment.uncommittedLoss])
        XCTAssertTrue(dirty.unattendedVerdict.allowed)
        _ = try WorktreeDeleter.deleteWorktree(worktreePath: dirtyWT, repoPath: repo, branchName: "dirty",
                                               deleteBranch: dirty.deletesBranch, force: dirty.unattendedVerdict.force,
                                               forceBranch: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirtyWT))

        let workWT = root + "/wt-work"
        git("worktree", "add", "-q", "-b", "work", workWT, in: repo)
        try "new\n".write(toFile: workWT + "/b.txt", atomically: true, encoding: .utf8)
        git("add", ".", in: workWT); git("commit", "-qm", "unpushed", in: workWT)
        let work = WorktreeDeleter.assessDeletion(worktreePath: workWT, repoPath: repo, branchName: "work")
        XCTAssertFalse(work.unattendedVerdict.allowed, "\(work.losses)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workWT))
    }

    func testDeletedReadsAsWords() {
        XCTAssertEqual(AutopilotCoordinator.compact(["deleted": true, "worktree_path": "/wt/report-membership-ya"]),
                       "deleted report-membership-ya")
    }
}
