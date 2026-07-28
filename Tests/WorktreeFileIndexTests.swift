import XCTest
@testable import seahelm

/// Covers the worktree-wide lookup behind the "Preview ▸" submenu: a bare
/// filename in terminal output resolving to the files that carry it.
final class WorktreeFileIndexTests: XCTestCase {
    private let index = WorktreeFileIndex(relativePaths: [
        "Sources/Usage/UsageSummary.swift",
        "Sources/UI/Island/IslandModel.swift",
        "Tests/UsageSummaryTests.swift",
        "app/models/user.rb",
        "app/views/user.rb",
        "user.rb",
        "vendor/misuse/user.rb",
    ])

    func testBareBasenameMatchesEveryCarrier() {
        XCTAssertEqual(
            Set(index.matches(token: "user.rb")),
            ["user.rb", "app/models/user.rb", "app/views/user.rb", "vendor/misuse/user.rb"]
        )
    }

    func testShallowestPathRanksFirst() {
        XCTAssertEqual(index.matches(token: "user.rb").first, "user.rb")
    }

    /// The pane's own directory is the likeliest referent for a bare name a tool
    /// printed while running there.
    func testPreferredDirectoryWinsOverDepth() {
        XCTAssertEqual(index.matches(token: "user.rb", preferring: "app/views").first, "app/views/user.rb")
        XCTAssertEqual(index.matches(token: "user.rb", preferring: "app/views/").first, "app/views/user.rb")
    }

    /// A partial path has to line up on a component boundary, or `misuse/user.rb`
    /// would answer for `use/user.rb`.
    func testPartialPathMatchesOnComponentBoundary() {
        XCTAssertEqual(index.matches(token: "models/user.rb"), ["app/models/user.rb"])
        XCTAssertTrue(index.matches(token: "use/user.rb").isEmpty)
        XCTAssertTrue(index.matches(token: "isuse/user.rb").isEmpty)
    }

    func testFullRelativePathMatchesItself() {
        XCTAssertEqual(index.matches(token: "app/models/user.rb"), ["app/models/user.rb"])
    }

    /// The same decorations the exact resolver strips: agents print
    /// `` `user.rb` `` and `user.rb:42`.
    func testDecoratedTokensStillMatch() {
        for token in ["user.rb:42", "`user.rb`", "(user.rb)", "user.rb,", "./user.rb"] {
            XCTAssertFalse(index.matches(token: token).isEmpty, "\(token) should match")
        }
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(index.matches(token: "USAGESUMMARY.SWIFT"), ["Sources/Usage/UsageSummary.swift"])
        XCTAssertEqual(index.matches(token: "usage/USAGESUMMARY.swift"), ["Sources/Usage/UsageSummary.swift"])
    }

    func testUnknownNameMatchesNothing() {
        XCTAssertTrue(index.matches(token: "nope.swift").isEmpty)
        XCTAssertTrue(index.matches(token: "").isEmpty)
        XCTAssertTrue(index.matches(token: "app/").isEmpty)
    }

    func testLimitCapsTheSubmenu() {
        XCTAssertEqual(index.matches(token: "user.rb", limit: 2).count, 2)
        XCTAssertTrue(index.matches(token: "user.rb", limit: 0).isEmpty)
    }

    func testDirectoriesAndLeadingDotSlashAreNormalisedAway() {
        let normalised = WorktreeFileIndex(relativePaths: ["./a/b.swift", "a/dir/", "", "c.swift"])
        XCTAssertEqual(normalised.relativePaths, ["a/b.swift", "c.swift"])
        XCTAssertEqual(normalised.matches(token: "b.swift"), ["a/b.swift"])
    }
}

final class WorktreeFileIndexStoreTests: XCTestCase {
    /// The menu is built synchronously, so a cold cache must answer immediately
    /// with nothing rather than block on the listing.
    func testFirstLookupIsColdThenWarms() {
        let store = WorktreeFileIndexStore()
        let built = expectation(description: "index built")
        store.listPaths = { _ in
            defer { built.fulfill() }
            return ["a/b.swift"]
        }

        XCTAssertNil(store.cachedIndex(for: "/tmp/wt"))
        wait(for: [built], timeout: 2)

        // Poll: the build completes on the store's own queue.
        let warmed = expectation(description: "cache populated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(store.cachedIndex(for: "/tmp/wt")?.relativePaths, ["a/b.swift"])
            warmed.fulfill()
        }
        wait(for: [warmed], timeout: 2)
    }

    func testEmptyWorktreePathIsIgnored() {
        let store = WorktreeFileIndexStore()
        store.listPaths = { _ in XCTFail("should not list for an empty path"); return [] }
        XCTAssertNil(store.cachedIndex(for: ""))
        store.warm("")
    }

    /// A throwaway repo: one tracked file, one untracked, one ignored. Using the
    /// real worktree here cost 11s per run — `--others` walks the tree.
    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "tracked".write(to: dir.appendingPathComponent("src/tracked.swift"), atomically: true, encoding: .utf8)
        try "fresh".write(to: dir.appendingPathComponent("src/untracked.swift"), atomically: true, encoding: .utf8)
        try "junk".write(to: dir.appendingPathComponent("ignored.log"), atomically: true, encoding: .utf8)
        try "*.log\n".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "src/tracked.swift"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = dir
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }
        return dir
    }

    /// Tracked-only is the fast phase the menu gets first.
    func testGitPathsListsTrackedFilesOnly() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let paths = try XCTUnwrap(WorktreeFileIndexStore.gitPaths(worktreePath: dir.path, includingUntracked: false))

        XCTAssertEqual(paths, ["src/tracked.swift"])
    }

    /// The slower second phase adds new files but still honours .gitignore.
    func testGitPathsWithUntrackedAddsNewFilesButNotIgnoredOnes() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let paths = try XCTUnwrap(WorktreeFileIndexStore.gitPaths(worktreePath: dir.path, includingUntracked: true))

        XCTAssertTrue(paths.contains("src/tracked.swift"))
        XCTAssertTrue(paths.contains("src/untracked.swift"))
        XCTAssertFalse(paths.contains("ignored.log"), "gitignored paths must stay out")
    }

    func testGitPathsReturnsNilOutsideARepository() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A bare temp dir is not a repo; the caller falls back to enumeration.
        if let paths = WorktreeFileIndexStore.gitPaths(worktreePath: dir.path, includingUntracked: false) {
            XCTAssertTrue(paths.isEmpty, "a non-repo must not yield tracked files")
        }
    }

    func testEnumeratedFallbackFindsFilesWithoutGit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("sub/note.txt").path, contents: Data("x".utf8))

        let paths = WorktreeFileIndexStore.enumeratedPaths(worktreePath: dir.path)

        XCTAssertTrue(paths.contains("sub/note.txt"))
        XCTAssertFalse(paths.contains("sub"), "directories are not previewable")
    }
}
