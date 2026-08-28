import XCTest
@testable import seahelm

/// The integration checkout and one full round through it.
final class IntegrationWorktreeTests: XCTestCase {

    private var tempDir: URL!

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    // MARK: - lifecycle

    /// Detached on purpose: a branch would be pushable, resettable, and would
    /// show up in the base picker for new worktrees.
    func testCreatedCheckoutIsDetachedAndLeavesNoBranch() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")

        XCTAssertEqual(gitOutput(["branch", "--show-current"], in: path), "")
        XCTAssertEqual(gitOutput(["rev-parse", "HEAD"], in: path),
                       gitOutput(["rev-parse", "main"], in: repo))
        XCTAssertFalse(gitOutput(["branch", "--list"], in: repo).contains("integration"))
    }

    func testCreateRefusesAnOccupiedPath() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        XCTAssertThrowsError(try IntegrationWorktree.create(repoPath: repo, at: path, base: "main"))
    }

    // MARK: - publishing

    func testPublishMovesTheCheckoutToTheBuiltCommit() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        let target = gitOutput(["rev-parse", "agentA"], in: repo)

        XCTAssertEqual(IntegrationWorktree.publish(commit: target, to: path), .published(commit: target))
        XCTAssertEqual(gitOutput(["rev-parse", "HEAD"], in: path), target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/a.txt"))
    }

    func testPublishingWhatIsAlreadyCheckedOutIsANoop() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        let head = gitOutput(["rev-parse", "HEAD"], in: path)
        XCTAssertEqual(IntegrationWorktree.publish(commit: head, to: path), .unchanged(commit: head))
    }

    /// Rebuilding an unchanged fleet yields a *different* commit — `commit-tree`
    /// stamps a timestamp — holding the same files. Publishing must recognise
    /// that as nothing to do, or every round resets the checkout for no reason
    /// and yanks files from under whatever is running there.
    func testARebuiltCommitWithTheSameTreeIsStillANoop() throws {
        let repo = try makeFleet()
        let worktrees = try addWorktrees(["agentA"], in: repo)
        let path = tempDir.appendingPathComponent("integration").path

        let first = try IntegrationRunner.run(repoPath: repo, integrationPath: path, worktrees: worktrees)
        XCTAssertEqual(first.outcome, .published(commit: first.result.commit))

        let second = try IntegrationRunner.run(repoPath: repo, integrationPath: path, worktrees: worktrees)
        XCTAssertEqual(second.result.tree, first.result.tree, "same fleet, same files")
        XCTAssertEqual(second.outcome, .unchanged(commit: second.result.commit))
        XCTAssertFalse(second.needsAttention)
        XCTAssertEqual(gitOutput(["rev-parse", "HEAD"], in: path), first.result.commit,
                       "an unchanged round must leave the checkout exactly where it was")
    }

    /// The one irreversible step in the feature. It must not fire on its own
    /// while someone is mid-edit in the integration checkout.
    func testLocalEditsHoldThePublishUntilForced() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        try "hand edit\n".write(toFile: path + "/base.txt", atomically: true, encoding: .utf8)
        let target = gitOutput(["rev-parse", "agentA"], in: repo)
        let headBefore = gitOutput(["rev-parse", "HEAD"], in: path)

        XCTAssertTrue(IntegrationWorktree.hasLocalEdits(at: path))
        XCTAssertEqual(
            IntegrationWorktree.publish(commit: target, to: path),
            .held(reason: .dirtyWorktree, commit: target)
        )
        XCTAssertEqual(gitOutput(["rev-parse", "HEAD"], in: path), headBefore, "a hold must not move HEAD")
        XCTAssertEqual(try String(contentsOfFile: path + "/base.txt", encoding: .utf8), "hand edit\n")

        XCTAssertEqual(
            IntegrationWorktree.publish(commit: target, to: path, force: true),
            .published(commit: target)
        )
        XCTAssertEqual(gitOutput(["rev-parse", "HEAD"], in: path), target)
    }

    /// Untracked files count as edits too — losing an agent's new file to a
    /// silent reset is the same accident as losing a modified one.
    func testUntrackedFilesAlsoHoldThePublish() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        try "scratch\n".write(toFile: path + "/scratch.txt", atomically: true, encoding: .utf8)
        let target = gitOutput(["rev-parse", "agentA"], in: repo)
        XCTAssertEqual(
            IntegrationWorktree.publish(commit: target, to: path),
            .held(reason: .dirtyWorktree, commit: target)
        )
    }

    // MARK: - a full round

    func testRunCreatesTheCheckoutAndIntegratesTheFleet() throws {
        let repo = try makeFleet()
        let worktrees = try addWorktrees(["agentA", "agentD"], in: repo)
        let path = tempDir.appendingPathComponent("integration").path

        let report = try IntegrationRunner.run(
            repoPath: repo, integrationPath: path, worktrees: worktrees
        )
        XCTAssertEqual(report.result.included.sorted(), ["agentA", "agentD"])
        XCTAssertEqual(report.outcome, .published(commit: report.result.commit))
        XCTAssertFalse(report.needsAttention, "a clean round should stay quiet")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/a.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/d.txt"))
    }

    func testRunReportsAConflictAndStaysBuildable() throws {
        let repo = try makeFleet()
        let worktrees = try addWorktrees(["agentB", "agentC"], in: repo)
        let path = tempDir.appendingPathComponent("integration").path

        let report = try IntegrationRunner.run(
            repoPath: repo, integrationPath: path, worktrees: worktrees
        )
        XCTAssertEqual(report.result.included, ["agentB"])
        XCTAssertEqual(report.result.excluded.map(\.label), ["agentC"])
        XCTAssertTrue(report.needsAttention)
        XCTAssertTrue(report.summary.contains("shared.txt"), report.summary)
        // No conflict markers reached the checkout: it still compiles.
        let shared = try String(contentsOfFile: path + "/shared.txt", encoding: .utf8)
        XCTAssertFalse(shared.contains("<<<<<<<"), shared)
    }

    /// The reason snapshots exist: an agent's turn ends before a commit.
    func testRunPicksUpUncommittedWorkInAWorktree() throws {
        let repo = try makeFleet()
        let worktrees = try addWorktrees(["agentA"], in: repo)
        try "in progress\n".write(toFile: worktrees[0].path + "/wip.txt", atomically: true, encoding: .utf8)
        let path = tempDir.appendingPathComponent("integration").path

        let report = try IntegrationRunner.run(
            repoPath: repo, integrationPath: path, worktrees: worktrees
        )
        XCTAssertEqual(report.result.included, ["agentA"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/wip.txt"))
    }

    /// The checkout must never merge itself back in.
    func testRunExcludesTheIntegrationCheckoutAndMain() throws {
        let repo = try makeFleet()
        var worktrees = try addWorktrees(["agentA"], in: repo)
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        worktrees.append(WorktreeInfo(path: path, branch: "", commitHash: "", isMainWorktree: false, isDetached: true))
        worktrees.append(WorktreeInfo(path: repo, branch: "main", commitHash: "", isMainWorktree: true))

        let report = try IntegrationRunner.run(
            repoPath: repo, integrationPath: path, worktrees: worktrees
        )
        XCTAssertEqual(report.result.included, ["agentA"])
    }

    func testSourceOrderIsStable() throws {
        let repo = try makeFleet()
        let worktrees = try addWorktrees(["agentD", "agentA"], in: repo)
        let first = IntegrationRunner.sources(from: worktrees, excluding: []).map(\.path)
        let second = IntegrationRunner.sources(from: worktrees.reversed(), excluding: []).map(\.path)
        XCTAssertEqual(first, second)
    }

    // MARK: - helpers

    private func addWorktrees(_ branches: [String], in repo: String) throws -> [WorktreeInfo] {
        try branches.map { branch in
            let path = tempDir.appendingPathComponent("wt-\(branch)").path
            runGit(["worktree", "add", path, branch], in: repo)
            return WorktreeInfo(path: path, branch: branch, commitHash: "", isMainWorktree: false)
        }
    }

    private func makeFleet() throws -> String {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-intwt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let repo = tempDir.appendingPathComponent("repo").path
        runGit(["init", "-b", "main", repo], in: tempDir.path)
        try "l1\nl2\nl3\n".write(toFile: repo + "/shared.txt", atomically: true, encoding: .utf8)
        try "base\n".write(toFile: repo + "/base.txt", atomically: true, encoding: .utf8)
        commitAll(repo, "base")
        try branch("agentA", in: repo) { try "A\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8) }
        try branch("agentB", in: repo) { try "l1\nBBB\nl3\n".write(toFile: repo + "/shared.txt", atomically: true, encoding: .utf8) }
        try branch("agentC", in: repo) { try "l1\nCCC\nl3\n".write(toFile: repo + "/shared.txt", atomically: true, encoding: .utf8) }
        try branch("agentD", in: repo) { try "D\n".write(toFile: repo + "/d.txt", atomically: true, encoding: .utf8) }
        runGit(["checkout", "main"], in: repo)
        return repo
    }

    private func branch(_ name: String, in repo: String, _ work: () throws -> Void) rethrows {
        runGit(["checkout", "-b", name, "main"], in: repo)
        try work()
        commitAll(repo, "\(name) work")
        runGit(["checkout", "main"], in: repo)
    }

    private func commitAll(_ repo: String, _ message: String) {
        runGit(["add", "-A"], in: repo)
        runGit(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", message], in: repo)
    }

    @discardableResult
    private func gitOutput(_ args: [String], in directory: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out; process.standardError = err
        try? process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runGit(_ args: [String], in directory: String) { gitOutput(args, in: directory) }
}
