import XCTest
@testable import seahelm

/// Covers `GhosttyNSView.resolveSelectedPath` — the pure path resolver behind the
/// pane context menu's "Preview" item.
final class SelectedFilePathResolutionTests: XCTestCase {

    private var tmpDir: String = ""

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory().appending("seahelm-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    private func touch(_ relative: String) throws -> String {
        let full = (tmpDir as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: full, contents: Data("x".utf8))
        return full
    }

    func testRelativePathResolvedAgainstBase() throws {
        let full = try touch("docs/remote-clients-design.md")
        let url = GhosttyNSView.resolveSelectedPath(
            raw: "docs/remote-clients-design.md",
            bases: [nil, "", tmpDir]
        )
        XCTAssertEqual(url?.path, full)
    }

    func testFirstExistingBaseWins() throws {
        let full = try touch("a/file.txt")
        let url = GhosttyNSView.resolveSelectedPath(
            raw: "a/file.txt",
            bases: ["/nonexistent/base", tmpDir]
        )
        XCTAssertEqual(url?.path, full)
    }

    func testTrailingWhitespaceTrimmed() throws {
        let full = try touch("notes.md")
        let url = GhosttyNSView.resolveSelectedPath(raw: "  notes.md \n", bases: [tmpDir])
        XCTAssertEqual(url?.path, full)
    }

    func testAbsolutePathUsedDirectly() throws {
        let full = try touch("abs.txt")
        let url = GhosttyNSView.resolveSelectedPath(raw: full, bases: [nil])
        XCTAssertEqual(url?.path, full)
    }

    func testNonexistentFileReturnsNil() {
        XCTAssertNil(GhosttyNSView.resolveSelectedPath(raw: "does/not/exist.md", bases: [tmpDir]))
    }

    func testDirectoryReturnsNil() throws {
        _ = try touch("subdir/keep.txt")  // creates subdir
        XCTAssertNil(GhosttyNSView.resolveSelectedPath(raw: "subdir", bases: [tmpDir]))
    }

    func testMultiTokenSelectionRejected() throws {
        _ = try touch("file.md")
        XCTAssertNil(GhosttyNSView.resolveSelectedPath(raw: "file.md Mobile", bases: [tmpDir]))
    }

    func testEmptySelectionReturnsNil() {
        XCTAssertNil(GhosttyNSView.resolveSelectedPath(raw: "   \n ", bases: [tmpDir]))
    }
}
