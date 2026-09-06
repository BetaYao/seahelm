import XCTest
@testable import seahelm

final class WorktreeReturnPlannerTests: XCTestCase {

    private func merged(branch: String = "task/x") -> WorktreeReturnFacts {
        var f = WorktreeReturnFacts(branch: branch)
        f.baseBranch = "main"
        f.fetchedBase = true
        f.baseOnRemote = true
        f.unshippedCommits = 0
        f.remote = .github(owner: "acme", repo: "app")
        f.hasGitHubToken = true
        return f
    }

    private func withWork(branch: String = "task/x") -> WorktreeReturnFacts {
        var f = merged(branch: branch)
        f.unshippedCommits = 2
        f.uncommittedFileCount = 3
        f.taskDescription = "add the login page"
        return f
    }

    // MARK: - Refusals

    func testRefusesMainIntegrationRunningAndMidMerge() {
        var f = merged(); f.isMain = true
        XCTAssertEqual(WorktreeReturnPlanner.plan(f), .refuse("is the main worktree — it cannot be returned."))
        f = merged(); f.isIntegration = true
        if case .refuse = WorktreeReturnPlanner.plan(f) {} else { XCTFail("integration checkout must be refused") }
        f = withWork(); f.agentRunning = true
        XCTAssertEqual(WorktreeReturnPlanner.plan(f), .refuse("has an agent running — leaving it alone."))
        f = withWork(); f.inMergeOrRebase = true
        if case .refuse(let why) = WorktreeReturnPlanner.plan(f) {
            XCTAssertTrue(why.contains("merge or rebase"))
        } else { XCTFail("mid-merge must be refused") }
    }

    func testDetachedHeadWithWorkIsRefusedButCleanDetachedIsDeleted() {
        var f = withWork(branch: ""); f.isDetached = true
        if case .refuse(let why) = WorktreeReturnPlanner.plan(f) {
            XCTAssertTrue(why.contains("detached"), why)
        } else { XCTFail("detached with work must be refused") }
        var clean = merged(branch: ""); clean.isDetached = true
        XCTAssertEqual(WorktreeReturnPlanner.plan(clean), .delete(deleteBranch: false, reason: "nothing beyond origin/main"))
    }

    func testWorkWithNoRemoteIsRefused() {
        var f = withWork(); f.remote = .none
        if case .refuse(let why) = WorktreeReturnPlanner.plan(f) {
            XCTAssertTrue(why.contains("no remote"), why)
        } else { XCTFail("no remote must be refused") }
    }

    // MARK: - Delete outright

    func testCleanAndMergedDeletesWorktreeAndBranch() {
        XCTAssertEqual(WorktreeReturnPlanner.plan(merged()),
                       .delete(deleteBranch: true, reason: "nothing beyond origin/main"))
    }

    /// The squash case: commits do not match one by one, the whole change does.
    func testSquashMergedCountsAsMerged() {
        var f = merged(); f.unshippedCommits = 2; f.squashMergedIntoBase = true
        XCTAssertEqual(WorktreeReturnPlanner.plan(f), .delete(deleteBranch: true, reason: "nothing beyond origin/main"))
    }

    func testTrunkBranchIsKeptWhenItsWorktreeGoes() {
        var f = merged(branch: "main"); f.branchIsTrunk = true
        XCTAssertEqual(WorktreeReturnPlanner.plan(f), .delete(deleteBranch: false, reason: "nothing beyond origin/main"))
    }

    func testLocalOnlyJudgementSaysSo() {
        var f = merged(); f.fetchedBase = false
        if case .delete(_, let reason) = WorktreeReturnPlanner.plan(f) {
            XCTAssertTrue(reason.contains("judged locally"), reason)
        } else { XCTFail("clean + merged must delete") }
    }

    // MARK: - Ship

    func testDirtyWorktreeCommitsPushesOpensPRDeletes() {
        XCTAssertEqual(WorktreeReturnPlanner.plan(withWork()), .ship([
            .commit(message: "add the login page", files: 3),
            .push(branch: "task/x"),
            .openPR(title: "add the login page", base: "main"),
            .delete(deleteBranch: true),
        ]))
    }

    func testCleanButUnmergedSkipsTheCommit() {
        var f = withWork(); f.uncommittedFileCount = 0
        XCTAssertEqual(WorktreeReturnPlanner.plan(f), .ship([
            .push(branch: "task/x"),
            .openPR(title: "add the login page", base: "main"),
            .delete(deleteBranch: true),
        ]))
    }

    func testNoTaskDescriptionFallsBackToTheBranchName() {
        var f = withWork(); f.taskDescription = nil
        XCTAssertEqual(WorktreeReturnPlanner.plan(f), .ship([
            .commit(message: "task/x", files: 3),
            .push(branch: "task/x"),
            .openPR(title: "task/x", base: "main"),
            .delete(deleteBranch: true),
        ]))
    }

    func testExistingPRIsNotDuplicated() {
        var f = withWork(); f.existingPRURL = "https://github.com/acme/app/pull/4"
        XCTAssertEqual(WorktreeReturnPlanner.plan(f), .ship([
            .commit(message: "add the login page", files: 3),
            .push(branch: "task/x"),
            .skipPR(reason: "a PR is already open: https://github.com/acme/app/pull/4"),
            .delete(deleteBranch: true),
        ]))
    }

    func testNoTokenPushesAndStillDeletes() {
        var f = withWork(); f.hasGitHubToken = false
        if case .ship(let steps) = WorktreeReturnPlanner.plan(f) {
            XCTAssertEqual(steps[2], .skipPR(reason: "no GitHub token — open the PR yourself"))
            XCTAssertEqual(steps.last, .delete(deleteBranch: true))
        } else { XCTFail("expected a ship plan") }
    }

    func testNonGitHubRemotePushesWithANote() {
        var f = withWork(); f.remote = .other(host: "gitlab.com")
        if case .ship(let steps) = WorktreeReturnPlanner.plan(f) {
            XCTAssertEqual(steps[2], .skipPR(reason: "origin is on gitlab.com, not GitHub — open the merge request yourself"))
            XCTAssertEqual(steps.last, .delete(deleteBranch: true))
        } else { XCTFail("expected a ship plan") }
    }

    /// A base that only exists locally cannot take a PR; the branch is pushed
    /// and the worktree stays.
    func testBaseMissingOnOriginPushesThenStops() {
        var f = withWork(); f.baseOnRemote = false
        if case .ship(let steps) = WorktreeReturnPlanner.plan(f) {
            XCTAssertEqual(steps[1], .push(branch: "task/x"))
            if case .stop(let reason) = steps[2] {
                XCTAssertTrue(reason.contains("main is not on origin"), reason)
            } else { XCTFail("expected a stop, got \(steps[2])") }
            XCTAssertEqual(steps.count, 3, "no delete after a stop")
        } else { XCTFail("expected a ship plan") }
    }

    // MARK: - Summary

    func testSummaryReadsAsOneLineInOrder() {
        let steps: [WorktreeReturnStep] = [
            .commit(message: "m", files: 1), .push(branch: "task/x"),
            .openPR(title: "t", base: "main"), .delete(deleteBranch: true),
        ]
        XCTAssertEqual(WorktreeReturnPlanner.summary(of: steps, label: "@task/x"),
                       "Return @task/x: commit 1 file → push task/x → open a PR against main → delete the worktree and its branch")
    }

    // MARK: - Runner over fakes

    func testRunnerStopsAtTheFirstFailureAndKeepsWhatItDid() {
        final class Git: WorktreeReturnGit {
            var log: [String] = []
            func commitAll(message: String) throws { log.append("commit \(message)") }
            func push(branch: String) throws { log.append("push"); throw WorktreeReturnError.git("rejected") }
            func commitSubjects(since base: String) -> [String] { [] }
        }
        let git = Git()
        let plan = WorktreeReturnPlan.ship([.commit(message: "m", files: 1), .push(branch: "b"), .delete(deleteBranch: true)])
        let outcome = WorktreeReturnRunner.run(plan, branch: "b", task: nil, git: git, pr: nil)
        XCTAssertEqual(git.log, ["commit m", "push"])
        XCTAssertEqual(outcome.completed, [.commit(message: "m", files: 1)])
        XCTAssertEqual(outcome.failure, "Push failed: rejected")
        XCTAssertFalse(outcome.deletesWorktree)
    }

    func testRunnerHonoursAStop() {
        final class Git: WorktreeReturnGit {
            func commitAll(message: String) throws {}
            func push(branch: String) throws {}
            func commitSubjects(since base: String) -> [String] { [] }
        }
        let plan = WorktreeReturnPlan.ship([.push(branch: "b"), .stop(reason: "base missing")])
        let outcome = WorktreeReturnRunner.run(plan, branch: "b", task: nil, git: Git(), pr: nil)
        XCTAssertNil(outcome.failure)
        XCTAssertFalse(outcome.deletesWorktree)
        XCTAssertEqual(outcome.notes, ["base missing"])
    }

    // MARK: - Remote parsing

    func testGitRemoteParsesTheThreeShapesGitWrites() {
        XCTAssertEqual(GitRemote.parse("git@github.com:BetaYao/seahelm.git"),
                       GitRemote(host: "github.com", owner: "BetaYao", repo: "seahelm"))
        XCTAssertEqual(GitRemote.parse("https://github.com/BetaYao/seahelm"),
                       GitRemote(host: "github.com", owner: "BetaYao", repo: "seahelm"))
        XCTAssertEqual(GitRemote.parse("ssh://git@github.com:22/BetaYao/seahelm.git"),
                       GitRemote(host: "github.com", owner: "BetaYao", repo: "seahelm"))
        XCTAssertEqual(GitRemote.parse("https://gitlab.com/group/sub/project.git")?.kind, .other(host: "gitlab.com"))
        XCTAssertEqual(GitRemote.parse("git@github.com:BetaYao/seahelm.git")?.kind, .github(owner: "BetaYao", repo: "seahelm"))
        XCTAssertNil(GitRemote.parse("/Users/me/repos/origin.git"))
        XCTAssertNil(GitRemote.parse(""))
    }
}
