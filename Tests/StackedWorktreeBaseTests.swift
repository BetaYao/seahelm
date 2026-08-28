import XCTest
@testable import seahelm

/// Covers the diff base for a worktree cut from another worktree's branch.
///
/// git records nothing about what a branch was created from, so the base used
/// to be guessed from a fixed list of trunk names. For a stacked worktree that
/// guess is wrong in a way that shows: the branch below it appears as its own
/// work. seahelm does know the base — the user picked it — so these lock in
/// that it is used, and that a stale record degrades rather than breaks.
final class StackedWorktreeBaseTests: XCTestCase {

    private var tempDir: URL!

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    /// The defect, end to end: `feat/ui` sits on `feat/api`, so `api.py` is not
    /// its work. Against trunk it was reported as such.
    func testStackedWorktreeExcludesTheBranchItSitsOn() throws {
        let repo = try makeStackedRepo()

        let stacked = GitDiff.branchChangedFiles(worktreePath: repo.uiWorktree, recordedBase: "feat/api")
        XCTAssertEqual(stacked.baseRef, "feat/api")
        XCTAssertEqual(Set(stacked.files.map(\.path)), ["ui.html"])

        // Without the record, the old trunk guess still reports both files —
        // this is the behaviour being fixed, kept here so the difference is
        // visible rather than asserted only in the negative.
        let guessed = GitDiff.branchChangedFiles(worktreePath: repo.uiWorktree, recordedBase: nil)
        XCTAssertEqual(guessed.baseRef, "main")
        XCTAssertEqual(Set(guessed.files.map(\.path)), ["api.py", "ui.html"])
    }

    func testRecordedBaseWins() throws {
        let repo = try makeStackedRepo()
        XCTAssertEqual(
            GitDiff.resolveBaseRef(worktreePath: repo.uiWorktree, recordedBase: "feat/api"),
            "feat/api"
        )
    }

    /// A base merged upstream and pruned must not leave the panel baseless.
    func testDeletedBaseFallsBackToTrunk() throws {
        let repo = try makeStackedRepo()
        XCTAssertEqual(
            GitDiff.resolveBaseRef(worktreePath: repo.uiWorktree, recordedBase: "feat/long-gone"),
            "main"
        )
    }

    func testNoRecordKeepsTheTrunkGuess() throws {
        let repo = try makeStackedRepo()
        XCTAssertEqual(
            GitDiff.resolveBaseRef(worktreePath: repo.uiWorktree, recordedBase: nil),
            "main"
        )
    }

    /// An empty or blank record is treated as no record, not as a ref named "".
    func testBlankRecordIsIgnored() throws {
        let repo = try makeStackedRepo()
        XCTAssertEqual(
            GitDiff.resolveBaseRef(worktreePath: repo.uiWorktree, recordedBase: "   "),
            "main"
        )
    }

    /// Uncommitted work in a stacked worktree still belongs to it.
    func testUncommittedWorkInAStackedWorktreeIsStillItsOwn() throws {
        let repo = try makeStackedRepo()
        try "draft\n".write(toFile: repo.uiWorktree + "/draft.txt", atomically: true, encoding: .utf8)

        let stacked = GitDiff.branchChangedFiles(worktreePath: repo.uiWorktree, recordedBase: "feat/api")
        XCTAssertEqual(Set(stacked.files.map(\.path)), ["ui.html", "draft.txt"])
    }

    // MARK: - helpers

    private struct StackedRepo {
        let root: String
        let uiWorktree: String
    }

    /// main ← feat/api (agent A) ← feat/ui (agent B), B in its own worktree.
    private func makeStackedRepo() throws -> StackedRepo {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-stacked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let repo = tempDir.appendingPathComponent("repo").path
        runGit(["init", "-b", "main", repo], in: tempDir.path)
        try "base\n".write(toFile: repo + "/base.txt", atomically: true, encoding: .utf8)
        commitAll(in: repo, message: "main: base")

        runGit(["checkout", "-b", "feat/api"], in: repo)
        try "def endpoint(): pass\n".write(toFile: repo + "/api.py", atomically: true, encoding: .utf8)
        commitAll(in: repo, message: "A: add endpoint")
        runGit(["checkout", "main"], in: repo)

        let ui = tempDir.appendingPathComponent("ui").path
        runGit(["worktree", "add", ui, "-b", "feat/ui", "feat/api"], in: repo)
        try "<div/>\n".write(toFile: ui + "/ui.html", atomically: true, encoding: .utf8)
        commitAll(in: ui, message: "B: build the UI")

        return StackedRepo(root: repo, uiWorktree: ui)
    }

    private func commitAll(in directory: String, message: String) {
        runGit(["add", "-A"], in: directory)
        runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com",
                "commit", "-m", message], in: directory)
    }

    private func runGit(_ args: [String], in directory: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let err = Pipe()
        process.standardOutput = Pipe()
        process.standardError = err
        try? process.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(data: errData, encoding: .utf8) ?? "")
    }
}
