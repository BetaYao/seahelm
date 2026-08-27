import XCTest
@testable import seahelm

/// Covers the +/- badge on the dashboard card. The case that matters most is
/// the untracked one: an agent writes new files and leaves staging to the user,
/// so a card driven by `git diff HEAD` alone reports nothing for a worktree the
/// agent just filled with code.
final class WorktreeGitStatsTests: XCTestCase {

    private var tempDir: URL!

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testUntrackedFileCountsTowardAdded() throws {
        let repo = try makeRepo()
        try "a\nb\nc\nd\n".write(toFile: repo + "/tracked.txt", atomically: true, encoding: .utf8)
        try "p\nq\n".write(toFile: repo + "/staged-new.txt", atomically: true, encoding: .utf8)
        runGit(["add", "staged-new.txt"], in: repo)
        try "x\ny\nz\n".write(toFile: repo + "/brand-new.txt", atomically: true, encoding: .utf8)

        // 1 tracked edit + 2 staged + 3 untracked.
        XCTAssertEqual(WorktreeGitStatsProvider.stats(worktreePath: repo).added, 6)
    }

    func testLastLineWithoutNewlineStillCounts() throws {
        let repo = try makeRepo()
        try "one\ntwo".write(toFile: repo + "/partial.txt", atomically: true, encoding: .utf8)

        XCTAssertEqual(WorktreeGitStatsProvider.untrackedAddedLines(worktreePath: repo), 2)
    }

    /// numstat prints "-" for binary blobs rather than a count, so the untracked
    /// pass must not invent one either.
    func testUntrackedBinaryFileContributesNothing() throws {
        let repo = try makeRepo()
        var bytes = Data([0x00, 0x01, 0x02])
        bytes.append(contentsOf: [UInt8](repeating: UInt8(ascii: "\n"), count: 40))
        try bytes.write(to: URL(fileURLWithPath: repo + "/blob.bin"))

        XCTAssertEqual(WorktreeGitStatsProvider.untrackedAddedLines(worktreePath: repo), 0)
    }

    /// `--exclude-standard`: build output is not the agent's work.
    func testIgnoredFilesAreNotCounted() throws {
        let repo = try makeRepo()
        try "build/\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
        runGit(["add", ".gitignore"], in: repo)
        runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com",
                "commit", "-m", "ignore build"], in: repo)
        try FileManager.default.createDirectory(atPath: repo + "/build", withIntermediateDirectories: true)
        try "junk\njunk\njunk\n".write(toFile: repo + "/build/out.txt", atomically: true, encoding: .utf8)

        XCTAssertEqual(WorktreeGitStatsProvider.untrackedAddedLines(worktreePath: repo), 0)
    }

    func testEmptyUntrackedFileCountsNoLines() throws {
        let repo = try makeRepo()
        FileManager.default.createFile(atPath: repo + "/empty.txt", contents: Data())

        XCTAssertEqual(WorktreeGitStatsProvider.untrackedAddedLines(worktreePath: repo), 0)
    }

    func testCleanWorktreeReportsNothing() throws {
        let repo = try makeRepo()
        let stats = WorktreeGitStatsProvider.stats(worktreePath: repo)
        XCTAssertEqual(stats.added, 0)
        XCTAssertEqual(stats.removed, 0)
        // No upstream configured — ahead/behind stay unknown rather than zero.
        XCTAssertNil(stats.ahead)
        XCTAssertNil(stats.behind)
        XCTAssertTrue(stats.isEmpty)
    }

    // MARK: - helpers

    private func makeRepo() throws -> String {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-gitstats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let repo = tempDir.appendingPathComponent("repo").path
        runGit(["init", "-b", "main", repo], in: tempDir.path)
        try "a\nb\nc\n".write(toFile: repo + "/tracked.txt", atomically: true, encoding: .utf8)
        runGit(["add", "."], in: repo)
        runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com",
                "commit", "-m", "init"], in: repo)
        return repo
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
