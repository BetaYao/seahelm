import XCTest
@testable import seahelm

/// Real git in a temp directory: a bare "origin" and a clone that plays the
/// worktree. Pushes go to the bare repo, so nothing leaves the machine.
final class WorktreeReturnRunnerTests: XCTestCase {
    private var root: URL!
    private var origin: String!
    private var work: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seahelm-return-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        origin = root.appendingPathComponent("origin.git").path
        work = root.appendingPathComponent("work").path
        try git(["init", "--bare", "-b", "main", origin], in: root.path)
        try git(["clone", "-q", origin, work], in: root.path)
        try identify(work)
        try write("README.md", "hello\n")
        try git(["add", "-A"], in: work)
        try git(["commit", "-q", "-m", "init"], in: work)
        try git(["push", "-q", "-u", "origin", "main"], in: work)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Runner

    func testShipCommitsPushesAndReportsDelete() throws {
        try git(["checkout", "-q", "-b", "task/x"], in: work)
        try write("feature.txt", "work\n")
        let plan = WorktreeReturnPlan.ship([
            .commit(message: "add feature", files: 1),
            .push(branch: "task/x"),
            .skipPR(reason: "no GitHub token"),
            .delete(deleteBranch: true),
        ])
        let outcome = WorktreeReturnRunner.run(plan, branch: "task/x", task: "add feature",
                                               git: WorktreeReturnGitProcess(worktreePath: work), pr: nil)
        XCTAssertNil(outcome.failure, outcome.failure ?? "")
        XCTAssertTrue(outcome.deletesWorktree)
        XCTAssertTrue(outcome.deletesBranch)
        XCTAssertEqual(outcome.notes, ["no GitHub token"])
        // The commit reached origin, which is what makes the worktree disposable.
        XCTAssertEqual(try git(["log", "-1", "--format=%s", "task/x"], in: origin), "add feature")
        XCTAssertEqual(try git(["status", "--porcelain"], in: work), "")
        XCTAssertTrue(try git(["log", "-1", "--format=%b", "task/x"], in: origin).contains("seahelm"))
    }

    func testRejectedPushStopsBeforeDelete() throws {
        try git(["checkout", "-q", "-b", "task/y"], in: work)
        try commitFile("a.txt", "a\n", message: "a", in: work)
        try git(["push", "-q", "-u", "origin", "task/y"], in: work)
        // Someone else moved the remote branch on.
        let other = root.appendingPathComponent("other").path
        try git(["clone", "-q", "-b", "task/y", origin, other], in: root.path)
        try identify(other)
        try commitFile("b.txt", "b\n", message: "b", in: other)
        try git(["push", "-q"], in: other)
        try commitFile("c.txt", "c\n", message: "c", in: work)

        let plan = WorktreeReturnPlan.ship([.push(branch: "task/y"), .delete(deleteBranch: true)])
        let outcome = WorktreeReturnRunner.run(plan, branch: "task/y", task: nil,
                                               git: WorktreeReturnGitProcess(worktreePath: work), pr: nil)
        XCTAssertTrue(outcome.failure?.hasPrefix("Push failed") == true, outcome.failure ?? "no failure")
        XCTAssertFalse(outcome.deletesWorktree)
        XCTAssertEqual(try git(["log", "-1", "--format=%s", "task/y"], in: origin), "b", "never forced")
    }

    func testPRStepUsesTheClientAndCarriesCommitSubjects() throws {
        try git(["checkout", "-q", "-b", "task/z"], in: work)
        try commitFile("z.txt", "z\n", message: "add z", in: work)
        final class FakePR: WorktreeReturnPRClient {
            var calls: [(title: String, body: String, head: String, base: String)] = []
            func createPR(title: String, body: String, head: String, base: String) throws -> String {
                calls.append((title, body, head, base))
                return "https://github.com/acme/x/pull/9"
            }
        }
        let pr = FakePR()
        let plan = WorktreeReturnPlan.ship([
            .push(branch: "task/z"), .openPR(title: "add z", base: "main"), .delete(deleteBranch: true),
        ])
        let outcome = WorktreeReturnRunner.run(plan, branch: "task/z", task: "add z",
                                               git: WorktreeReturnGitProcess(worktreePath: work), pr: pr)
        XCTAssertNil(outcome.failure, outcome.failure ?? "")
        XCTAssertEqual(outcome.prURL, "https://github.com/acme/x/pull/9")
        XCTAssertEqual(pr.calls.count, 1)
        XCTAssertEqual(pr.calls[0].head, "task/z")
        XCTAssertEqual(pr.calls[0].base, "main")
        XCTAssertTrue(pr.calls[0].body.contains("- add z"), pr.calls[0].body)
        XCTAssertTrue(pr.calls[0].body.contains("Opened by seahelm"), pr.calls[0].body)
    }

    // MARK: - Assessment

    func testAssessmentSeesUncommittedWorkAndUnshippedCommits() throws {
        try git(["checkout", "-q", "-b", "task/a"], in: work)
        try commitFile("a.txt", "a\n", message: "a", in: work)
        try write("dirty.txt", "d\n")
        let facts = WorktreeReturnAssessor.assess(worktreePath: work, repoPath: work, branch: "task/a",
                                                  isMain: false, isDetached: false, recordedBase: "main")
        XCTAssertEqual(facts.uncommittedFileCount, 1)
        XCTAssertEqual(facts.unshippedCommits, 1)
        XCTAssertTrue(facts.fetchedBase)
        XCTAssertTrue(facts.baseOnRemote)
        XCTAssertFalse(facts.isMerged)
        XCTAssertFalse(facts.inMergeOrRebase)
        XCTAssertFalse(facts.branchIsTrunk)
        // A path is not a host: a local origin is no GitHub, and no host at all.
        XCTAssertEqual(facts.remote, .none)
    }

    func testAssessmentSeesAMergedBranchAsNothingToShip() throws {
        try git(["checkout", "-q", "-b", "task/m"], in: work)
        try commitFile("m.txt", "m\n", message: "m", in: work)
        try git(["push", "-q", "-u", "origin", "task/m"], in: work)
        try git(["push", "-q", "origin", "task/m:main"], in: work)   // fast-forward merge on origin
        let facts = WorktreeReturnAssessor.assess(worktreePath: work, repoPath: work, branch: "task/m",
                                                  isMain: false, isDetached: false, recordedBase: "main")
        XCTAssertEqual(facts.unshippedCommits, 0)
        XCTAssertTrue(facts.isMerged)
        XCTAssertEqual(WorktreeReturnPlanner.plan(facts), .delete(deleteBranch: true, reason: "nothing beyond origin/main"))
    }

    /// The case commit-by-commit comparison cannot see: two commits squashed
    /// into one on main. `/return` must read that as merged, or it would push
    /// and try to open a PR for work that is already in.
    func testAssessmentRecognisesASquashMerge() throws {
        try git(["checkout", "-q", "-b", "task/s"], in: work)
        try commitFile("s1.txt", "1\n", message: "s1", in: work)
        try commitFile("s2.txt", "2\n", message: "s2", in: work)
        // The squash merge happens "on GitHub": a second clone squashes into main and pushes.
        let merger = root.appendingPathComponent("merger").path
        try git(["clone", "-q", origin, merger], in: root.path)
        try identify(merger)
        try git(["fetch", "-q", work, "task/s:task/s"], in: merger)
        try git(["merge", "--squash", "-q", "task/s"], in: merger)
        try git(["commit", "-q", "-m", "task/s (#1)"], in: merger)
        try git(["push", "-q", "origin", "main"], in: merger)

        let facts = WorktreeReturnAssessor.assess(worktreePath: work, repoPath: work, branch: "task/s",
                                                  isMain: false, isDetached: false, recordedBase: "main")
        XCTAssertEqual(facts.unshippedCommits, 2, "commit by commit, both still look unshipped")
        XCTAssertTrue(facts.squashMergedIntoBase)
        XCTAssertTrue(facts.isMerged)
        XCTAssertEqual(WorktreeReturnPlanner.plan(facts), .delete(deleteBranch: true, reason: "nothing beyond origin/main"))
    }

    func testAssessmentFlagsAMergeInProgress() throws {
        try git(["checkout", "-q", "-b", "task/c"], in: work)
        try commitFile("README.md", "left\n", message: "left", in: work)
        try git(["checkout", "-q", "main"], in: work)
        try commitFile("README.md", "right\n", message: "right", in: work)
        try git(["checkout", "-q", "task/c"], in: work)
        _ = run(["merge", "main"], in: work)   // conflicts, leaves MERGE_HEAD behind
        XCTAssertTrue(WorktreeReturnAssessor.isMergeOrRebaseInProgress(worktreePath: work))
        let facts = WorktreeReturnAssessor.assess(worktreePath: work, repoPath: work, branch: "task/c",
                                                  isMain: false, isDetached: false, recordedBase: "main")
        if case .refuse(let why) = WorktreeReturnPlanner.plan(facts) {
            XCTAssertTrue(why.contains("merge or rebase"), why)
        } else { XCTFail("a conflicted merge must be refused") }
    }

    // MARK: - Helpers

    @discardableResult
    private func run(_ args: [String], in dir: String) -> (ok: Bool, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try? p.run()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (p.terminationStatus == 0, stdout.trimmingCharacters(in: .whitespacesAndNewlines), stderr)
    }

    @discardableResult
    private func git(_ args: [String], in dir: String) throws -> String {
        let r = run(args, in: dir)
        guard r.ok else {
            throw NSError(domain: "git", code: 1, userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")): \(r.err)"])
        }
        return r.out
    }

    private func identify(_ dir: String) throws {
        try git(["config", "user.email", "tester@example.com"], in: dir)
        try git(["config", "user.name", "Tester"], in: dir)
        try git(["config", "commit.gpgsign", "false"], in: dir)
    }

    private func write(_ name: String, _ text: String, in dir: String? = nil) throws {
        try text.write(toFile: (dir ?? work).appending("/" + name), atomically: true, encoding: .utf8)
    }

    private func commitFile(_ name: String, _ text: String, message: String, in dir: String) throws {
        try write(name, text, in: dir)
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", message], in: dir)
    }
}
