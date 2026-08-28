import XCTest
@testable import seahelm

/// The snapshot primitive: a worktree's current state as a commit, taken
/// without the worktree noticing.
final class WorktreeSnapshotterTests: XCTestCase {

    private var tempDir: URL!

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    /// Nothing outstanding: the snapshot is HEAD, and no objects are written.
    func testCleanWorktreeSnapshotsAsHeadItself() throws {
        let repo = try makeRepo()
        let snapshot = try XCTUnwrap(WorktreeSnapshotter.snapshot(worktreePath: repo))
        XCTAssertTrue(snapshot.isClean)
        XCTAssertEqual(snapshot.commit, snapshot.head)
        XCTAssertEqual(snapshot.commit, gitOutput(["rev-parse", "HEAD"], in: repo))
    }

    /// The case `git stash create` gets wrong, and the reason this exists.
    func testSnapshotCapturesUntrackedFiles() throws {
        let repo = try makeRepo()
        try "brand new\n".write(toFile: repo + "/untracked.txt", atomically: true, encoding: .utf8)

        let snapshot = try XCTUnwrap(WorktreeSnapshotter.snapshot(worktreePath: repo))
        XCTAssertFalse(snapshot.isClean)
        XCTAssertEqual(filesIn(commit: snapshot.commit, repo: repo), ["tracked.txt", "untracked.txt"])
    }

    func testSnapshotCapturesModificationsAndDeletions() throws {
        let repo = try makeRepo()
        try "changed\n".write(toFile: repo + "/tracked.txt", atomically: true, encoding: .utf8)
        try "second\n".write(toFile: repo + "/second.txt", atomically: true, encoding: .utf8)
        runGit(["add", "second.txt"], in: repo)
        runGit(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "add second"], in: repo)
        try FileManager.default.removeItem(atPath: repo + "/second.txt")

        let snapshot = try XCTUnwrap(WorktreeSnapshotter.snapshot(worktreePath: repo))
        XCTAssertEqual(filesIn(commit: snapshot.commit, repo: repo), ["tracked.txt"])
        XCTAssertEqual(show(path: "tracked.txt", commit: snapshot.commit, repo: repo), "changed\n")
    }

    /// The whole point: an agent working in the directory must not be able to
    /// tell a snapshot happened.
    func testSnapshotLeavesWorktreeIndexAndHeadUntouched() throws {
        let repo = try makeRepo()
        try "dirty\n".write(toFile: repo + "/tracked.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: repo + "/untracked.txt", atomically: true, encoding: .utf8)
        let statusBefore = gitOutput(["status", "--porcelain"], in: repo)
        let headBefore = gitOutput(["rev-parse", "HEAD"], in: repo)
        let branchBefore = gitOutput(["branch", "--show-current"], in: repo)

        _ = WorktreeSnapshotter.snapshot(worktreePath: repo)

        XCTAssertEqual(gitOutput(["status", "--porcelain"], in: repo), statusBefore)
        XCTAssertEqual(gitOutput(["rev-parse", "HEAD"], in: repo), headBefore)
        XCTAssertEqual(gitOutput(["branch", "--show-current"], in: repo), branchBefore)
    }

    func testIgnoredFilesAreNotSnapshotted() throws {
        let repo = try makeRepo()
        try "build/\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
        runGit(["add", ".gitignore"], in: repo)
        runGit(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "ignore build"], in: repo)
        try FileManager.default.createDirectory(atPath: repo + "/build", withIntermediateDirectories: true)
        try "junk\n".write(toFile: repo + "/build/out.txt", atomically: true, encoding: .utf8)

        let snapshot = try XCTUnwrap(WorktreeSnapshotter.snapshot(worktreePath: repo))
        XCTAssertTrue(snapshot.isClean, "only ignored noise is not a change")
    }

    /// The dedup key the coordinator will poll on: same files, same tree.
    func testTreeIsStableForIdenticalContent() throws {
        let repo = try makeRepo()
        try "same\n".write(toFile: repo + "/untracked.txt", atomically: true, encoding: .utf8)
        let first = try XCTUnwrap(WorktreeSnapshotter.snapshot(worktreePath: repo))
        let second = try XCTUnwrap(WorktreeSnapshotter.snapshot(worktreePath: repo))
        XCTAssertEqual(first.tree, second.tree)

        try "different\n".write(toFile: repo + "/untracked.txt", atomically: true, encoding: .utf8)
        let third = try XCTUnwrap(WorktreeSnapshotter.snapshot(worktreePath: repo))
        XCTAssertNotEqual(first.tree, third.tree)
    }

    /// A repo with no commit has nothing to snapshot on top of.
    func testUnbornBranchYieldsNoSnapshot() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let repo = tempDir.appendingPathComponent("empty").path
        runGit(["init", "-b", "main", repo], in: tempDir.path)
        XCTAssertNil(WorktreeSnapshotter.snapshot(worktreePath: repo))
    }

    // MARK: - helpers

    private func makeRepo() throws -> String {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let repo = tempDir.appendingPathComponent("repo").path
        runGit(["init", "-b", "main", repo], in: tempDir.path)
        try "base\n".write(toFile: repo + "/tracked.txt", atomically: true, encoding: .utf8)
        runGit(["add", "-A"], in: repo)
        runGit(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "init"], in: repo)
        return repo
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
