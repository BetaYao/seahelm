import XCTest
@testable import seahelm

/// Combining several worktrees into one commit, entirely in the object
/// database. The property that matters most is negative: none of this may
/// touch a worktree, because that is what makes it safe to run unattended.
final class IntegrationBuilderTests: XCTestCase {

    private var tempDir: URL!

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    // MARK: - parsing

    func testParseCleanMergeIsJustATree() {
        let outcome = IntegrationBuilder.parseMergeTree("abc123\0")
        XCTAssertEqual(outcome?.tree, "abc123")
        XCTAssertEqual(outcome?.conflictingPaths, [])
    }

    /// The empty field closes the path list; everything after it is git's
    /// informational block and must not be read as a path.
    func testParseConflictStopsAtTheEmptyField() {
        let output = "abc123\0shared.txt\0src/app.swift\0\0" + "1\0shared.txt\0Auto-merging\0"
        let outcome = IntegrationBuilder.parseMergeTree(output)
        XCTAssertEqual(outcome?.tree, "abc123")
        XCTAssertEqual(outcome?.conflictingPaths, ["shared.txt", "src/app.swift"])
    }

    func testParseRejectsEmptyOutput() {
        XCTAssertNil(IntegrationBuilder.parseMergeTree(""))
        XCTAssertNil(IntegrationBuilder.parseMergeTree("\0"))
    }

    // MARK: - building

    func testIndependentSourcesAllMergeIn() throws {
        let repo = try makeFleet()
        let result = try XCTUnwrap(IntegrationBuilder.build(
            repoPath: repo,
            base: "main",
            sources: [source("agentA", repo: repo), source("agentD", repo: repo)]
        ))
        XCTAssertEqual(result.included, ["agentA", "agentD"])
        XCTAssertTrue(result.excluded.isEmpty)
        XCTAssertFalse(result.hasConflicts)
        XCTAssertEqual(filesIn(commit: result.commit, repo: repo),
                       ["a.txt", "base.txt", "d.txt", "shared.txt"])
    }

    /// The default: keep the result testable by dropping the source that will
    /// not merge, and say which one and on what.
    func testConflictingSourceIsExcludedAndReported() throws {
        let repo = try makeFleet()
        let result = try XCTUnwrap(IntegrationBuilder.build(
            repoPath: repo,
            base: "main",
            sources: [source("agentB", repo: repo), source("agentC", repo: repo)]
        ))
        XCTAssertEqual(result.included, ["agentB"])
        XCTAssertEqual(result.excluded, [
            IntegrationExclusion(label: "agentC", conflictingPaths: ["shared.txt"]),
        ])
        XCTAssertTrue(result.conflictedPaths.isEmpty)
        // agentB won the file, and agentC's own work went with the exclusion.
        XCTAssertEqual(show(path: "shared.txt", commit: result.commit, repo: repo), "l1\nBBB\nl3\n")
        XCTAssertFalse(filesIn(commit: result.commit, repo: repo).contains("c_extra.txt"))
    }

    /// The other mode: nothing is dropped, and the conflict is carried in the
    /// tree as markers. Note `c_extra.txt` — the work that exclusion costs.
    func testIncludeWithMarkersKeepsEverything() throws {
        let repo = try makeFleet()
        let result = try XCTUnwrap(IntegrationBuilder.build(
            repoPath: repo,
            base: "main",
            sources: [source("agentB", repo: repo), source("agentC", repo: repo)],
            mode: .includeWithMarkers
        ))
        XCTAssertEqual(result.included, ["agentB", "agentC"])
        XCTAssertTrue(result.excluded.isEmpty)
        XCTAssertEqual(result.conflictedPaths, ["shared.txt"])
        XCTAssertTrue(filesIn(commit: result.commit, repo: repo).contains("c_extra.txt"))
        let shared = show(path: "shared.txt", commit: result.commit, repo: repo)
        XCTAssertTrue(shared.contains("<<<<<<<"), shared)
        XCTAssertTrue(shared.contains("BBB"), shared)
        XCTAssertTrue(shared.contains("CCC"), shared)
    }

    /// Which of two colliding sources is reported depends on order, so the
    /// order given must be the order applied — same input, same answer.
    func testOrderDecidesWhichSideIsExcludedAndIsStable() throws {
        let repo = try makeFleet()
        let bFirst = try XCTUnwrap(IntegrationBuilder.build(
            repoPath: repo, base: "main",
            sources: [source("agentB", repo: repo), source("agentC", repo: repo)]))
        let cFirst = try XCTUnwrap(IntegrationBuilder.build(
            repoPath: repo, base: "main",
            sources: [source("agentC", repo: repo), source("agentB", repo: repo)]))
        XCTAssertEqual(bFirst.excluded.map(\.label), ["agentC"])
        XCTAssertEqual(cFirst.excluded.map(\.label), ["agentB"])

        // The tree, not the commit: `commit-tree` stamps a timestamp, so two
        // rounds a second apart over the same fleet produce different commits
        // holding identical files. That is exactly why `tree` is the change key
        // the publish path compares.
        let repeated = try XCTUnwrap(IntegrationBuilder.build(
            repoPath: repo, base: "main",
            sources: [source("agentB", repo: repo), source("agentC", repo: repo)]))
        XCTAssertEqual(repeated.tree, bFirst.tree)
        XCTAssertEqual(repeated.included, bFirst.included)
        XCTAssertEqual(repeated.excluded, bFirst.excluded)
    }

    /// The change key has to survive the timestamp that makes commits differ,
    /// or the "nothing changed, do nothing" path never fires.
    func testTreeIsStableAcrossRebuildsWhileCommitsAreNot() throws {
        let repo = try makeFleet()
        let sources = [source("agentA", repo: repo), source("agentD", repo: repo)]
        let first = try XCTUnwrap(IntegrationBuilder.build(repoPath: repo, base: "main", sources: sources))
        let second = try XCTUnwrap(IntegrationBuilder.build(repoPath: repo, base: "main", sources: sources))
        XCTAssertEqual(first.tree, second.tree)
        XCTAssertEqual(first.tree, gitOutput(["rev-parse", "\(first.commit)^{tree}"], in: repo))
    }

    func testNoSourcesYieldsTheBaseItself() throws {
        let repo = try makeFleet()
        let result = try XCTUnwrap(IntegrationBuilder.build(repoPath: repo, base: "main", sources: []))
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.commit, result.base)
    }

    func testUnknownBaseYieldsNothing() throws {
        let repo = try makeFleet()
        XCTAssertNil(IntegrationBuilder.build(repoPath: repo, base: "no/such/ref", sources: []))
    }

    /// A source git cannot merge at all is excluded like any other, rather than
    /// abandoning the round.
    func testUnresolvableSourceIsExcludedNotFatal() throws {
        let repo = try makeFleet()
        let bogus = IntegrationSource(label: "ghost", commit: String(repeating: "0", count: 40))
        let result = try XCTUnwrap(IntegrationBuilder.build(
            repoPath: repo, base: "main",
            sources: [bogus, source("agentA", repo: repo)]))
        XCTAssertEqual(result.included, ["agentA"])
        XCTAssertEqual(result.excluded.map(\.label), ["ghost"])
    }

    /// The safety property the whole design rests on.
    func testBuildingTouchesNoWorktree() throws {
        let repo = try makeFleet()
        let statusBefore = gitOutput(["status", "--porcelain"], in: repo)
        let headBefore = gitOutput(["rev-parse", "HEAD"], in: repo)
        let branchBefore = gitOutput(["branch", "--show-current"], in: repo)

        _ = IntegrationBuilder.build(
            repoPath: repo, base: "main",
            sources: [source("agentB", repo: repo), source("agentC", repo: repo)])

        XCTAssertEqual(gitOutput(["status", "--porcelain"], in: repo), statusBefore)
        XCTAssertEqual(gitOutput(["rev-parse", "HEAD"], in: repo), headBefore)
        XCTAssertEqual(gitOutput(["branch", "--show-current"], in: repo), branchBefore)
    }

    /// End to end with the snapshotter: uncommitted work integrates too, which
    /// is the point — an agent's turn usually ends before a commit.
    func testUncommittedWorkIntegratesViaSnapshot() throws {
        let repo = try makeFleet()
        let worktree = tempDir.appendingPathComponent("wtA").path
        runGit(["worktree", "add", worktree, "agentA"], in: repo)
        try "in progress\n".write(toFile: worktree + "/wip.txt", atomically: true, encoding: .utf8)

        let snapshot = try XCTUnwrap(WorktreeSnapshotter.snapshot(worktreePath: worktree))
        let result = try XCTUnwrap(IntegrationBuilder.build(
            repoPath: repo, base: "main",
            sources: [IntegrationSource(label: "agentA", commit: snapshot.commit)]))

        XCTAssertEqual(result.included, ["agentA"])
        XCTAssertTrue(filesIn(commit: result.commit, repo: repo).contains("wip.txt"))
    }

    // MARK: - helpers

    private func source(_ branch: String, repo: String) -> IntegrationSource {
        IntegrationSource(label: branch, commit: gitOutput(["rev-parse", branch], in: repo))
    }

    /// main, plus four branches: A and D independent, B and C fighting over the
    /// same line of `shared.txt`. C also carries unrelated work, so exclusion
    /// has a visible cost.
    private func makeFleet() throws -> String {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let repo = tempDir.appendingPathComponent("repo").path
        runGit(["init", "-b", "main", repo], in: tempDir.path)
        try "l1\nl2\nl3\n".write(toFile: repo + "/shared.txt", atomically: true, encoding: .utf8)
        try "base\n".write(toFile: repo + "/base.txt", atomically: true, encoding: .utf8)
        commitAll(repo, "base")

        try branch("agentA", from: "main", in: repo) {
            try "A\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        }
        try branch("agentB", from: "main", in: repo) {
            try "l1\nBBB\nl3\n".write(toFile: repo + "/shared.txt", atomically: true, encoding: .utf8)
        }
        try branch("agentC", from: "main", in: repo) {
            try "l1\nCCC\nl3\n".write(toFile: repo + "/shared.txt", atomically: true, encoding: .utf8)
            try "C\n".write(toFile: repo + "/c_extra.txt", atomically: true, encoding: .utf8)
        }
        try branch("agentD", from: "main", in: repo) {
            try "D\n".write(toFile: repo + "/d.txt", atomically: true, encoding: .utf8)
        }
        runGit(["checkout", "main"], in: repo)
        return repo
    }

    private func branch(_ name: String, from base: String, in repo: String, _ work: () throws -> Void) rethrows {
        runGit(["checkout", "-b", name, base], in: repo)
        try work()
        commitAll(repo, "\(name) work")
        runGit(["checkout", base], in: repo)
    }

    private func commitAll(_ repo: String, _ message: String) {
        runGit(["add", "-A"], in: repo)
        runGit(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", message], in: repo)
    }

    private func filesIn(commit: String, repo: String) -> [String] {
        gitOutput(["ls-tree", "-r", "--name-only", commit], in: repo)
            .split(separator: "\n").map(String.init).sorted()
    }

    private func show(path: String, commit: String, repo: String) -> String {
        gitOutput(["show", "\(commit):\(path)"], in: repo, trim: false)
    }

    @discardableResult
    private func gitOutput(_ args: [String], in directory: String, trim: Bool = true) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out; process.standardError = err
        try? process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(data: errData, encoding: .utf8) ?? "")
        let text = String(data: data, encoding: .utf8) ?? ""
        return trim ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    private func runGit(_ args: [String], in directory: String) {
        gitOutput(args, in: directory)
    }
}
