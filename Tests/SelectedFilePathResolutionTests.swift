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

    /// `src/a.ts:42` is how every agent and compiler prints a location; the
    /// suffix used to make the token miss on disk and hide the Preview item.
    func testLineAndColumnSuffixStripped() throws {
        let full = try touch("src/app.ts")
        for token in ["src/app.ts:42", "src/app.ts:42:7"] {
            XCTAssertEqual(
                GhosttyNSView.resolveSelectedPath(raw: token, bases: [tmpDir])?.path,
                full, "\(token) should resolve"
            )
        }
    }

    func testWrappingPunctuationStripped() throws {
        let full = try touch("src/app.ts")
        for token in ["`src/app.ts`", "(src/app.ts)", "\"src/app.ts\"", "'src/app.ts',",
                      "[src/app.ts]", "src/app.ts。", "src/app.ts，"] {
            XCTAssertEqual(
                GhosttyNSView.resolveSelectedPath(raw: token, bases: [tmpDir])?.path,
                full, "\(token) should resolve"
            )
        }
    }

    /// Unwrapping must not invent a hit: a file that genuinely ends in the
    /// stripped punctuation still resolves as typed, before any cleaning.
    func testLiteralFormIsTriedBeforeCleaning() throws {
        let full = try touch("weird.name.")
        XCTAssertEqual(
            GhosttyNSView.resolveSelectedPath(raw: "weird.name.", bases: [tmpDir])?.path,
            full
        )
    }

    /// A selection is a deliberate act, so a filename with spaces in it is
    /// honoured. Guessing from a click keeps the stricter rule.
    func testSelectionAllowsSpacesInTheName() throws {
        let full = try touch("docs/my design notes.md")
        XCTAssertEqual(
            GhosttyNSView.resolveSelectedPath(raw: "docs/my design notes.md", bases: [tmpDir], allowingSpaces: true)?.path,
            full
        )
        XCTAssertNil(GhosttyNSView.resolveSelectedPath(raw: "docs/my design notes.md", bases: [tmpDir]))
    }

    func testSelectionSpanningLinesIsStillRejected() throws {
        _ = try touch("a.txt")
        XCTAssertNil(GhosttyNSView.resolveSelectedPath(raw: "a.txt\nb.txt", bases: [tmpDir], allowingSpaces: true))
    }

    func testCleaningDoesNotResolveNonexistentFiles() {
        XCTAssertNil(GhosttyNSView.resolveSelectedPath(raw: "`nope/missing.ts:9`", bases: [tmpDir]))
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

    // MARK: - Multiple files on one line

    /// A line naming several real files should offer all of them. Picking only
    /// the nearest made the menu look broken whenever the click landed a cell
    /// off — `AGENTS.md / CLAUDE.md` is two files a space apart.
    func testEveryResolvableTokenIsReturnedInOrder() throws {
        let agents = try touch("AGENTS.md")
        let claude = try touch("CLAUDE.md")

        let urls = GhosttyNSView.resolvableFiles(
            in: ["AGENTS.md", "CLAUDE.md", "没动"], bases: [tmpDir])

        XCTAssertEqual(urls.map(\.path), [agents, claude])
    }

    /// Tokens arrive nearest-click-first, and that order is what the submenu
    /// shows — the file you clicked nearest is the first choice.
    func testOrderFollowsTheTokenOrder() throws {
        let agents = try touch("AGENTS.md")
        let claude = try touch("CLAUDE.md")

        let urls = GhosttyNSView.resolvableFiles(in: ["CLAUDE.md", "AGENTS.md"], bases: [tmpDir])

        XCTAssertEqual(urls.map(\.path), [claude, agents])
    }

    func testDuplicateTokensCollapse() throws {
        let file = try touch("dup.md")
        let urls = GhosttyNSView.resolvableFiles(in: ["dup.md", "./dup.md", "dup.md"],
                                                 bases: [tmpDir])
        XCTAssertEqual(urls.map(\.path), [file])
    }

    /// A trailing directory on the same line contributes nothing rather than a
    /// choice that would open to nothing.
    func testDirectoriesAreNotOffered() throws {
        let file = try touch("real.md")
        _ = try touch("docs/inner.md")   // creates docs/

        let urls = GhosttyNSView.resolvableFiles(in: ["real.md", "docs/"], bases: [tmpDir])

        XCTAssertEqual(urls.map(\.path), [file])
    }

    func testNoResolvableTokensReturnsEmpty() {
        XCTAssertTrue(GhosttyNSView.resolvableFiles(in: ["没动", "四份文档。"],
                                                    bases: [tmpDir]).isEmpty)
    }

}
