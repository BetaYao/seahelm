import XCTest
@testable import seahelm

final class FileChangeWatcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fcw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - ExternalChange

    func testOwnSaveOrUnchangedFileIsIgnored() {
        XCTAssertEqual(ExternalChange.decide(disk: "a", buffer: "a", saved: "a"), .ignore)
        XCTAssertEqual(ExternalChange.decide(disk: "a", buffer: "a+edit", saved: "a"), .ignore)
        XCTAssertEqual(ExternalChange.decide(disk: nil, buffer: "a", saved: "a"), .ignore, "deleted or unreadable")
    }

    func testCleanBufferReloads() {
        XCTAssertEqual(ExternalChange.decide(disk: "b", buffer: "a", saved: "a"), .reload)
    }

    func testDirtyBufferAsks() {
        XCTAssertEqual(ExternalChange.decide(disk: "b", buffer: "a+edit", saved: "a"), .conflict)
    }

    func testDiskCatchingUpWithTheBufferIsAdopted() {
        XCTAssertEqual(ExternalChange.decide(disk: "a+edit", buffer: "a+edit", saved: "a"), .adopt)
    }

    // MARK: - Watcher

    /// In-place writes and the write-temp-then-rename save agents use both
    /// report, and the watcher keeps watching after a rename.
    func testReportsInPlaceWritesAndAtomicReplaces() throws {
        let file = dir.appendingPathComponent("page.html")
        try "v1".write(to: file, atomically: false, encoding: .utf8)
        var fired = 0
        var expectation = self.expectation(description: "in-place write")
        let watcher = FileChangeWatcher(path: file.path) {
            fired += 1
            expectation.fulfill()
        }
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.2)  // let it arm

        try "v2".write(to: file, atomically: false, encoding: .utf8)
        wait(for: [expectation], timeout: 2)

        expectation = self.expectation(description: "atomic replace")
        try "v3".write(to: file, atomically: true, encoding: .utf8)
        wait(for: [expectation], timeout: 2)

        expectation = self.expectation(description: "still watching after the rename")
        try "v4".write(to: file, atomically: true, encoding: .utf8)
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(fired, 3)
    }

    func testStoppedWatcherIsSilent() throws {
        let file = dir.appendingPathComponent("a.md")
        try "v1".write(to: file, atomically: false, encoding: .utf8)
        let silent = expectation(description: "no report")
        silent.isInverted = true
        let watcher = FileChangeWatcher(path: file.path) { silent.fulfill() }
        Thread.sleep(forTimeInterval: 0.2)
        watcher.stop()
        try "v2".write(to: file, atomically: false, encoding: .utf8)
        wait(for: [silent], timeout: 0.6)
    }

    // MARK: - Editor

    func testCleanEditorShowsTheDiskTextAndDirtyOneAsks() {
        let file = dir.appendingPathComponent("x.md")
        let editor = CodeEditorView(fileURL: file, text: "one")
        editor.applyDiskTextForTesting("two")
        XCTAssertEqual(editor.bufferTextForTesting, "two")
        XCTAssertFalse(editor.isDirty)
        XCTAssertFalse(editor.isShowingConflictBannerForTesting)

        editor.typeForTesting("two, edited")
        editor.applyDiskTextForTesting("three")
        XCTAssertEqual(editor.bufferTextForTesting, "two, edited", "the user's edits are not thrown away")
        XCTAssertTrue(editor.isShowingConflictBannerForTesting)
    }
}
