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
            .held(reason: .dirtyWorktree(paths: ["base.txt"]), commit: target)
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
            .held(reason: .dirtyWorktree(paths: ["scratch.txt"]), commit: target)
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

    /// A round is triggered by one agent finishing but folds in every
    /// worktree. One that is still mid-turn contributes its HEAD, not a torn
    /// working tree — half a file failing the integration would look like a
    /// real conflict.
    func testBusyWorktreeContributesItsCommittedWorkOnly() throws {
        let repo = try makeFleet()
        let worktrees = try addWorktrees(["agentA"], in: repo)
        try "half written\n".write(toFile: worktrees[0].path + "/torn.txt", atomically: true, encoding: .utf8)
        let path = tempDir.appendingPathComponent("integration").path

        let report = try IntegrationRunner.run(
            repoPath: repo, integrationPath: path, worktrees: worktrees,
            isBusy: { _ in true }
        )
        XCTAssertEqual(report.result.included, ["agentA"])
        XCTAssertEqual(report.committedOnly, ["agentA"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/a.txt"), "its commit is in")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/torn.txt"),
                       "its half-written file is not")
        // An agent still working is the normal case, so a partial round stays
        // quiet: the note is ambient on the card, not a card of its own.
        XCTAssertFalse(report.needsAttention)
        XCTAssertTrue(report.cardLine.contains("1 still working"), report.cardLine)
    }

    /// The same worktree comes in whole once its turn ends.
    func testWorkArrivesInFullOnTheRoundAfterTheAgentStops() throws {
        let repo = try makeFleet()
        let worktrees = try addWorktrees(["agentA"], in: repo)
        try "now finished\n".write(toFile: worktrees[0].path + "/torn.txt", atomically: true, encoding: .utf8)
        let path = tempDir.appendingPathComponent("integration").path

        _ = try IntegrationRunner.run(repoPath: repo, integrationPath: path,
                                      worktrees: worktrees, isBusy: { _ in true })
        let after = try IntegrationRunner.run(repoPath: repo, integrationPath: path,
                                              worktrees: worktrees, isBusy: { _ in false })
        XCTAssertTrue(after.committedOnly.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/torn.txt"))
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

    // MARK: - reset to trunk

    func testResetTargetPrefersOriginMainOverLocalMain() throws {
        let repo = try makeFleet()
        XCTAssertEqual(IntegrationWorktree.resetTarget(repoPath: repo, fetch: false)?.ref, "main")

        runGit(["update-ref", "refs/remotes/origin/main", "main"], in: repo)
        let target = IntegrationWorktree.resetTarget(repoPath: repo, fetch: false)
        XCTAssertEqual(target?.ref, "origin/main")
        XCTAssertEqual(target?.commit, gitOutput(["rev-parse", "main"], in: repo))
    }

    /// The row's Reset: a checkout full of seahelm's own rounds goes straight
    /// back to trunk — HEAD *is* trunk afterwards, not merely the same files.
    func testResetMovesACheckoutSeahelmPublishedBackOntoTrunk() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        let round = gitOutput(["rev-parse", "agentA"], in: repo)
        XCTAssertEqual(IntegrationWorktree.publish(commit: round, to: path), .published(commit: round))

        // Trunk moves on underneath.
        try "trunk moved\n".write(toFile: repo + "/base.txt", atomically: true, encoding: .utf8)
        commitAll(repo, "trunk moves")
        runGit(["update-ref", "refs/remotes/origin/main", "main"], in: repo)
        let target = try XCTUnwrap(IntegrationWorktree.resetTarget(repoPath: repo, fetch: false))

        let outcome = IntegrationWorktree.reset(to: target, at: path, expectedHead: round)

        XCTAssertEqual(outcome, .published(commit: target.commit))
        XCTAssertEqual(gitOutput(["rev-parse", "HEAD"], in: path), gitOutput(["rev-parse", "main"], in: repo))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/a.txt"), "the round's files are gone")
    }

    func testResetOfACheckoutAlreadyOnTrunkIsANoop() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        let target = try XCTUnwrap(IntegrationWorktree.resetTarget(repoPath: repo, fetch: false))

        XCTAssertEqual(IntegrationWorktree.reset(to: target, at: path), .unchanged(commit: target.commit))
    }

    /// Same rule as publish: a reset is the one irreversible step, and it does
    /// not walk over edits made here without being told to.
    func testResetHoldsOnLocalEditsUntilForced() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        try "hand edit\n".write(toFile: path + "/base.txt", atomically: true, encoding: .utf8)
        let target = try XCTUnwrap(IntegrationWorktree.resetTarget(repoPath: repo, fetch: false))

        XCTAssertEqual(
            IntegrationWorktree.reset(to: target, at: path),
            .held(reason: .dirtyWorktree(paths: ["base.txt"]), commit: target.commit)
        )
        XCTAssertEqual(IntegrationWorktree.reset(to: target, at: path, force: true), .published(commit: target.commit))
        XCTAssertEqual(try String(contentsOfFile: path + "/base.txt"), "base\n")
    }

    func testResetHoldsOnACommitMadeInTheCheckout() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        let created = gitOutput(["rev-parse", "HEAD"], in: path)
        try "resolved by hand\n".write(toFile: path + "/shared.txt", atomically: true, encoding: .utf8)
        commitAll(path, "hand-resolved")
        let byHand = gitOutput(["rev-parse", "HEAD"], in: path)
        let target = try XCTUnwrap(IntegrationWorktree.resetTarget(repoPath: repo, fetch: false))

        XCTAssertEqual(
            IntegrationWorktree.reset(to: target, at: path, expectedHead: created),
            .held(reason: .movedHead(head: byHand), commit: target.commit)
        )
    }

    // MARK: - delete assessment

    /// A checkout sitting where seahelm left it is throwaway: it deletes
    /// without a sheet, and never takes a branch with it (there is none).
    func testDeletingAnUntouchedCheckoutIsSafe() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        let round = gitOutput(["rev-parse", "agentA"], in: repo)
        XCTAssertEqual(IntegrationWorktree.publish(commit: round, to: path), .published(commit: round))

        let assessment = IntegrationWorktree.assessDeletion(path: path, repoPath: repo, expectedHead: round)

        XCTAssertTrue(assessment.isSafe, assessment.losses.joined(separator: " / "))
        XCTAssertFalse(assessment.deletesBranch)
    }

    func testDeletingACheckoutWithHandEditsNamesThem() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        try "hand edit\n".write(toFile: path + "/base.txt", atomically: true, encoding: .utf8)

        let assessment = IntegrationWorktree.assessDeletion(path: path, repoPath: repo, expectedHead: nil)

        XCTAssertEqual(assessment.losses, [IntegrationHoldReason.dirtyWorktree(paths: ["base.txt"]).lossDescription])
        XCTAssertTrue(assessment.losses[0].contains("base.txt"))
    }

    // MARK: - work that arrived by hand

    /// The hole the dirty check cannot see: committing in the checkout leaves it
    /// clean, so `reset --hard` used to walk straight over it. A hand-resolved
    /// conflict is exactly the work that lands this way.
    func testACommitMadeInTheCheckoutHoldsThePublish() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        let published = gitOutput(["rev-parse", "HEAD"], in: path)

        try "resolved by hand\n".write(toFile: path + "/shared.txt", atomically: true, encoding: .utf8)
        runGit(["add", "-A"], in: path)
        runGit(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "hand resolve"], in: path)
        let handMade = gitOutput(["rev-parse", "HEAD"], in: path)
        XCTAssertFalse(IntegrationWorktree.hasLocalEdits(at: path), "a commit leaves the checkout clean")

        let target = gitOutput(["rev-parse", "agentA"], in: repo)
        XCTAssertEqual(
            IntegrationWorktree.publish(commit: target, to: path, expectedHead: published),
            .held(reason: .movedHead(head: handMade), commit: target)
        )
        XCTAssertEqual(gitOutput(["rev-parse", "HEAD"], in: path), handMade, "a hold must not move HEAD")

        XCTAssertEqual(
            IntegrationWorktree.publish(commit: target, to: path, force: true, expectedHead: published),
            .published(commit: target)
        )
    }

    /// The case that matters on the first launch after an upgrade: a checkout
    /// carrying a hand-made merge has no recorded head to compare against, and
    /// waiting a round to learn one would be a round too late. The commit's own
    /// identity answers instead — seahelm's rounds are committed as seahelm.
    func testAHandMergeHoldsEvenWithNothingRecorded() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        runGit(["-c", "user.name=t", "-c", "user.email=t@t", "merge", "--no-ff", "-m", "hand merge", "agentA"],
               in: path)
        let handMade = gitOutput(["rev-parse", "HEAD"], in: path)

        let target = gitOutput(["rev-parse", "agentD"], in: repo)
        XCTAssertEqual(
            IntegrationWorktree.publish(commit: target, to: path, expectedHead: nil, base: "main"),
            .held(reason: .movedHead(head: handMade), commit: target)
        )
    }

    /// The counterpart: a checkout still sitting where it was created holds
    /// nothing of its own, so it must not hold just because trunk's tip is a
    /// commit some human authored.
    func testACheckoutStillAtTrunkPublishesWithNothingRecorded() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        let target = gitOutput(["rev-parse", "agentA"], in: repo)
        XCTAssertEqual(
            IntegrationWorktree.publish(commit: target, to: path, expectedHead: nil, base: "main"),
            .published(commit: target)
        )
    }

    /// With neither a recorded head nor a base there is nothing to reason from,
    /// and a guard that guesses is worse than no guard.
    func testNoRecordedHeadMeansNoMovedHeadHold() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        let target = gitOutput(["rev-parse", "agentA"], in: repo)
        XCTAssertEqual(
            IntegrationWorktree.publish(commit: target, to: path, expectedHead: nil),
            .published(commit: target)
        )
    }

    /// Same files, different commit: there is no reset to hold back, so a stray
    /// commit that changed nothing must not freeze the checkout forever.
    func testAMovedHeadWithTheSameTreeIsStillANoop() throws {
        let repo = try makeFleet()
        let path = tempDir.appendingPathComponent("integration").path
        try IntegrationWorktree.create(repoPath: repo, at: path, base: "main")
        let published = gitOutput(["rev-parse", "HEAD"], in: path)
        runGit(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "empty"], in: path)

        XCTAssertEqual(
            IntegrationWorktree.publish(commit: published, to: path, expectedHead: published),
            .unchanged(commit: published)
        )
    }

    /// A checkout this round created is its own provenance — the first publish
    /// into a brand new checkout must not hold on a head seahelm just wrote.
    func testFirstRoundIntoAFreshCheckoutPublishes() throws {
        let repo = try makeFleet()
        let worktrees = try addWorktrees(["agentA"], in: repo)
        let path = tempDir.appendingPathComponent("integration").path

        let report = try IntegrationRunner.run(repoPath: repo, integrationPath: path, worktrees: worktrees)
        XCTAssertEqual(report.outcome, .published(commit: report.result.commit))
    }

    // MARK: - status parsing

    /// A rename appends its origin as a field of its own; reading that as
    /// another entry would list a file that is not in the way at all.
    func testStatusParsingSkipsRenameOrigins() {
        let raw = "R  new.txt\0old.txt\0 M other.txt\0?? scratch.txt\0"
        XCTAssertEqual(
            IntegrationWorktree.parseStatusPaths(raw),
            ["new.txt", "other.txt", "scratch.txt"]
        )
    }

}
