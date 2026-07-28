import XCTest
@testable import seahelm

final class WorktreePathIndexTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-path-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private func touch(_ relative: String, isDirectory: Bool = false) throws {
        let url = root.appendingPathComponent(relative)
        if isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }
    }

    func testPrunesNoiseDirectories() {
        XCTAssertTrue(WorktreePathIndex.shouldPruneDirectory(named: "node_modules"))
        XCTAssertTrue(WorktreePathIndex.shouldPruneDirectory(named: "build"))
        XCTAssertTrue(WorktreePathIndex.shouldPruneDirectory(named: ".git"))
        XCTAssertTrue(WorktreePathIndex.shouldPruneDirectory(named: ".build"))
        XCTAssertFalse(WorktreePathIndex.shouldPruneDirectory(named: "Sources"))
    }

    func testEnumerateSkipsPrunedTreesAndHiddenWhenDisabled() throws {
        try touch("Sources/App.swift")
        try touch("node_modules/pkg/index.js")
        try touch("build/out.o")
        try touch(".hidden/secret.swift")
        try touch("Sources/.env")

        let entries = WorktreePathIndex.enumerate(root: root, showHidden: false)
        let paths = Set(entries.map(\.relativePath))

        XCTAssertTrue(paths.contains("Sources/App.swift"))
        XCTAssertFalse(paths.contains("node_modules/pkg/index.js"))
        XCTAssertFalse(paths.contains("build/out.o"))
        XCTAssertFalse(paths.contains(".hidden/secret.swift"))
        XCTAssertFalse(paths.contains("Sources/.env"))
    }

    func testEnumerateIncludesHiddenWhenEnabled() throws {
        try touch("Sources/.env")
        try touch(".config/settings.json")

        let entries = WorktreePathIndex.enumerate(root: root, showHidden: true)
        let paths = Set(entries.map(\.relativePath))

        XCTAssertTrue(paths.contains("Sources/.env"))
        XCTAssertTrue(paths.contains(".config/settings.json"))
        // Still prune even when showing hidden.
        try touch(".git/config")
        let again = WorktreePathIndex.enumerate(root: root, showHidden: true)
        XCTAssertFalse(again.map(\.relativePath).contains(".git/config"))
    }

    func testMatchingKeepsBasenameHitsAndDirectoryNameHits() throws {
        try touch("Sources/Foo.swift")
        try touch("Sources/Bar.swift")
        try touch("Tests/FooTests.swift")
        try touch("Extras/lib/util.swift")

        let entries = WorktreePathIndex.enumerate(root: root, showHidden: false)
        let hits = WorktreePathIndex.matching(entries: entries, needle: "foo")
        let paths = Set(hits.map(\.relativePath))

        XCTAssertEqual(paths, Set(["Sources/Foo.swift", "Tests/FooTests.swift"]))
    }

    func testMatchingDirectoryNameIncludesTheDirectoryEntry() throws {
        try touch("Sources/App", isDirectory: true)
        try touch("Sources/App/Main.swift")

        let entries = WorktreePathIndex.enumerate(root: root, showHidden: false)
        let hits = WorktreePathIndex.matching(entries: entries, needle: "app")
        let paths = Set(hits.map(\.relativePath))

        // Basename match only — same as the previous tree filter: a matching
        // directory appears even when none of its children match the needle.
        XCTAssertTrue(paths.contains("Sources/App"))
        XCTAssertFalse(paths.contains("Sources/App/Main.swift"))
    }

    func testBuildFilteredTreeKeepsAncestorsOnly() throws {
        let matched = [
            WorktreePathEntry(relativePath: "Sources/UI/Foo.swift", isDirectory: false),
            WorktreePathEntry(relativePath: "Sources/Core/Bar.swift", isDirectory: false),
        ]
        let roots = WorktreePathIndex.buildFilteredTree(root: root, matched: matched)
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].url.lastPathComponent, "Sources")
        let kids = try XCTUnwrap(roots[0].children)
        let names = Set(kids.map { $0.url.lastPathComponent })
        XCTAssertEqual(names, Set(["UI", "Core"]))
    }

    func testEmptyNeedleReturnsNoFilterNeeded() {
        XCTAssertTrue(WorktreePathIndex.matching(entries: [
            WorktreePathEntry(relativePath: "a.swift", isDirectory: false)
        ], needle: "   ").isEmpty)
    }

    func testMatchingRespectsLimit() {
        let entries = (0..<50).map {
            WorktreePathEntry(relativePath: "f\($0).swift", isDirectory: false)
        }
        let hits = WorktreePathIndex.matching(entries: entries, needle: "f", limit: 10)
        XCTAssertEqual(hits.count, 10)
    }

    func testBuildFilteredTreeMarksAncestorsAsDirectories() throws {
        let matched = [
            WorktreePathEntry(relativePath: "a/b/c.swift", isDirectory: false),
        ]
        let roots = WorktreePathIndex.buildFilteredTree(root: root, matched: matched)
        XCTAssertEqual(roots.count, 1)
        XCTAssertTrue(roots[0].isDirectory)
        let b = try XCTUnwrap(roots[0].children?.first)
        XCTAssertEqual(b.url.lastPathComponent, "b")
        XCTAssertTrue(b.isDirectory)
        let file = try XCTUnwrap(b.children?.first)
        XCTAssertEqual(file.url.lastPathComponent, "c.swift")
        XCTAssertFalse(file.isDirectory)
    }
}
