import XCTest
@testable import seahelm

final class GitDiffTests: XCTestCase {

    // MARK: - parseNameStatus

    func testParseNameStatusModifiedAndAdded() {
        let output = "M\0f.txt\0A\0g.txt\0"
        let entries = GitDiff.parseNameStatus(output)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].path, "f.txt")
        XCTAssertEqual(entries[0].status, .modified)
        XCTAssertEqual(entries[0].stage, .unstaged)
        XCTAssertEqual(entries[1].path, "g.txt")
        XCTAssertEqual(entries[1].status, .added)
    }

    func testParseNameStatusRename() {
        let output = "R100\0old.txt\0new.txt\0"
        let entries = GitDiff.parseNameStatus(output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, "new.txt")
        XCTAssertEqual(entries[0].oldPath, "old.txt")
        XCTAssertEqual(entries[0].status, .renamed)
    }

    func testParseNameStatusDeleted() {
        let output = "D\0gone.txt\0"
        let entries = GitDiff.parseNameStatus(output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, "gone.txt")
        XCTAssertEqual(entries[0].status, .deleted)
    }

    // MARK: - branch-relative listing (real git)

    private var tempDir: URL!

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testBranchChangesIncludeCommittedFilesAfterCommit() throws {
        let repo = try makeRepoWithFeatureBranch()

        // Dirty edit + untracked, then commit the tracked edit — list must keep
        // the committed file (vs main) and still show untracked.
        try "feature-body\n".write(toFile: repo + "/tracked.txt", atomically: true, encoding: .utf8)
        try "brand-new\n".write(toFile: repo + "/untracked.txt", atomically: true, encoding: .utf8)
        _ = runGit(["add", "tracked.txt"], in: repo)
        _ = runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com",
                    "commit", "-m", "feature commit"], in: repo)

        let branch = GitDiff.branchChangedFiles(worktreePath: repo)
        XCTAssertEqual(branch.baseRef, "main")
        let paths = Set(branch.files.map(\.path))
        XCTAssertTrue(paths.contains("tracked.txt"), "committed-on-branch file should remain visible")
        XCTAssertTrue(paths.contains("untracked.txt"), "untracked file should remain visible")
        XCTAssertFalse(paths.contains("shared.txt"))
    }

    func testSnapshotKeepsCommittedDiffAfterCleanWorkingTree() throws {
        let repo = try makeRepoWithFeatureBranch()
        try "feature-body\n".write(toFile: repo + "/tracked.txt", atomically: true, encoding: .utf8)
        _ = runGit(["add", "tracked.txt"], in: repo)
        _ = runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com",
                    "commit", "-m", "feature commit"], in: repo)

        let snapshot = GitDiff.snapshot(worktreePath: repo)
        XCTAssertTrue(snapshot.changedFiles.contains { $0.path == "tracked.txt" })
        XCTAssertTrue(snapshot.files.contains { $0.path == "tracked.txt" && !$0.hunks.isEmpty })
    }

    func testSnapshotCanLoadOnlySelectedFile() throws {
        let repo = try makeRepoWithFeatureBranch()
        try "tracked-feature\n".write(toFile: repo + "/tracked.txt", atomically: true, encoding: .utf8)
        try "shared-feature\n".write(toFile: repo + "/shared.txt", atomically: true, encoding: .utf8)

        let snapshot = GitDiff.snapshot(worktreePath: repo, selectedPath: "tracked.txt")

        XCTAssertEqual(snapshot.changedFiles.map(\.path), ["tracked.txt"])
        XCTAssertEqual(snapshot.files.map(\.path), ["tracked.txt"])
        XCTAssertEqual(snapshot.totalChangedFileCount, 1)
    }

    func testDiffReviewSelectedPathUsesSingleFileLayout() {
        let view = DiffReviewView(
            worktreePath: "/tmp/worktree",
            selectedPath: "Sources/App/Main.swift",
            loadSnapshot: { GitDiffSnapshot(changedFiles: [], files: []) }
        )

        XCTAssertFalse(view.isFileListVisibleForTesting)
    }

    func testDiffReviewDefaultLayoutKeepsFileList() {
        let view = DiffReviewView(
            worktreePath: "/tmp/worktree",
            loadSnapshot: { GitDiffSnapshot(changedFiles: [], files: []) }
        )

        XCTAssertTrue(view.isFileListVisibleForTesting)
    }

    func testOnMainCleanWorkingTreeShowsNoBranchChanges() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-gitdiff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let repo = tempDir.appendingPathComponent("repo").path
        _ = runGit(["init", "-b", "main", repo], in: tempDir.path)
        try "shared\n".write(toFile: repo + "/shared.txt", atomically: true, encoding: .utf8)
        _ = runGit(["add", "."], in: repo)
        _ = runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com",
                    "commit", "-m", "init"], in: repo)

        let branch = GitDiff.branchChangedFiles(worktreePath: repo)
        XCTAssertEqual(branch.baseRef, "main")
        XCTAssertTrue(branch.files.isEmpty)
        XCTAssertEqual(branch.totalCount, 0)
    }

    func testCapToRecentFilesKeepsNewest() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-gitdiff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let root = tempDir.path

        let older = GitChangedFile(path: "old.txt", oldPath: nil, status: .modified, stage: .unstaged)
        let newer = GitChangedFile(path: "new.txt", oldPath: nil, status: .modified, stage: .unstaged)
        let newest = GitChangedFile(path: "newest.txt", oldPath: nil, status: .added, stage: .untracked)

        try "a\n".write(toFile: root + "/old.txt", atomically: true, encoding: .utf8)
        try "b\n".write(toFile: root + "/new.txt", atomically: true, encoding: .utf8)
        try "c\n".write(toFile: root + "/newest.txt", atomically: true, encoding: .utf8)

        let past = Date().addingTimeInterval(-3600)
        let mid = Date().addingTimeInterval(-60)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: root + "/old.txt")
        try FileManager.default.setAttributes([.modificationDate: mid], ofItemAtPath: root + "/new.txt")
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: root + "/newest.txt")

        let capped = GitDiff.capToRecentFiles([older, newer, newest], worktreePath: root, limit: 2)
        XCTAssertEqual(capped.map(\.path), ["newest.txt", "new.txt"])
    }

    func testBranchChangesRespectsLimitAndReportsTotal() throws {
        let repo = try makeRepoWithFeatureBranch()
        for i in 0..<5 {
            let name = "f\(i).txt"
            try "body-\(i)\n".write(toFile: repo + "/" + name, atomically: true, encoding: .utf8)
            // Stagger mtimes so capping is deterministic.
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(TimeInterval(i))],
                ofItemAtPath: repo + "/" + name
            )
        }

        let branch = GitDiff.branchChangedFiles(worktreePath: repo, limit: 2)
        XCTAssertEqual(branch.totalCount, 5)
        XCTAssertTrue(branch.isTruncated)
        XCTAssertEqual(branch.files.count, 2)
        XCTAssertEqual(Set(branch.files.map(\.path)), Set(["f3.txt", "f4.txt"]))
    }

    // MARK: - helpers

    private func makeRepoWithFeatureBranch() throws -> String {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-gitdiff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let repo = tempDir.appendingPathComponent("repo").path
        _ = runGit(["init", "-b", "main", repo], in: tempDir.path)
        try "shared\n".write(toFile: repo + "/shared.txt", atomically: true, encoding: .utf8)
        try "base\n".write(toFile: repo + "/tracked.txt", atomically: true, encoding: .utf8)
        _ = runGit(["add", "."], in: repo)
        _ = runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com",
                    "commit", "-m", "init"], in: repo)
        _ = runGit(["checkout", "-b", "feat"], in: repo)
        return repo
    }

    @discardableResult
    private func runGit(_ args: [String], in directory: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try? process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
