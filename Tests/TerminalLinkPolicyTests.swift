import XCTest
@testable import seahelm

/// Covers the rules behind "Cmd+click a link in the terminal": what may open,
/// what has to ask first, and what is refused outright.
final class TerminalLinkPolicyTests: XCTestCase {

    // MARK: - Visible text (a URL matched in the grid)

    func testVisibleHTTPSOpens() {
        XCTAssertEqual(
            TerminalLinkPolicy.decide(origin: .visibleText, raw: "https://github.com/owner/repo/pull/1394"),
            .open(URL(string: "https://github.com/owner/repo/pull/1394")!)
        )
    }

    func testVisibleMailtoOpens() {
        let decision = TerminalLinkPolicy.decide(origin: .visibleText, raw: "mailto:dev@example.com")
        guard case .open(let url) = decision else { return XCTFail("expected open, got \(decision)") }
        XCTAssertEqual(url.scheme, "mailto")
    }

    func testVisibleTextToleratesSurroundingWhitespace() {
        XCTAssertEqual(
            TerminalLinkPolicy.decide(origin: .visibleText, raw: "  https://example.com  "),
            .open(URL(string: "https://example.com")!)
        )
    }

    func testVisibleEmptyIsIgnored() {
        XCTAssertEqual(TerminalLinkPolicy.decide(origin: .visibleText, raw: "   "), .ignore)
    }

    /// The default link regex also matches bare paths, so a `.rs` file printed
    /// by a tool is a link too. libghostty resolves those against the pane's
    /// working directory first, and one that no longer resolves must not put a
    /// modal alert in front of the pane.
    func testVisibleStalePathIsIgnoredQuietly() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-gone-\(UUID().uuidString).rs")
        XCTAssertEqual(TerminalLinkPolicy.decide(origin: .visibleText, raw: missing.path), .ignore)
    }

    func testVisibleUnresolvedRelativePathIsIgnoredQuietly() {
        XCTAssertEqual(
            TerminalLinkPolicy.decide(origin: .visibleText, raw: "apps/desktop/src/main.rs"),
            .ignore
        )
    }

    /// libghostty resolves a relative path against the pane's cwd before it
    /// sends the action, so whatever arrives is already absolute.
    func testVisibleExistingFileOpens() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-link-\(UUID().uuidString).txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        guard case .open(let url) = TerminalLinkPolicy.decide(origin: .visibleText, raw: file.path) else {
            return XCTFail("expected open")
        }
        XCTAssertEqual(url.path, file.resolvingSymlinksInPath().path)
    }

    /// The one visible-text shape that can still execute something.
    func testVisibleExecutableFileIsRefused() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-link-\(UUID().uuidString).command")
        try "#!/bin/sh\necho hi\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        guard case .deny = TerminalLinkPolicy.decide(origin: .visibleText, raw: file.path) else {
            return XCTFail("expected deny for a .command file")
        }
    }

    // MARK: - OSC 8 hyperlinks

    func testHyperlinkHTTPSOpens() {
        XCTAssertEqual(
            TerminalLinkPolicy.decide(origin: .hyperlink, raw: "https://example.com/a?b=c#d"),
            .open(URL(string: "https://example.com/a?b=c#d")!)
        )
    }

    /// OSC 8 can point anywhere regardless of the text it is drawn under, so a
    /// malformed target is refused rather than guessed at.
    func testHyperlinkSchemeLessIsRefused() {
        guard case .deny = TerminalLinkPolicy.decide(origin: .hyperlink, raw: "example.com/x") else {
            return XCTFail("expected deny")
        }
    }

    func testHyperlinkUnknownSchemeAsksFirst() {
        guard case .confirm(let url) = TerminalLinkPolicy.decide(origin: .hyperlink, raw: "vscode://file/tmp/x") else {
            return XCTFail("expected confirm for a custom scheme")
        }
        XCTAssertEqual(url.scheme, "vscode")
    }

    func testHyperlinkExecutableFileIsRefused() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-payload-\(UUID().uuidString).command")
        try "#!/bin/sh\necho pwned\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let target = URL(fileURLWithPath: file.path).absoluteString
        guard case .deny(let reason) = TerminalLinkPolicy.decide(origin: .hyperlink, raw: target) else {
            return XCTFail("expected deny for an executable file target")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testHyperlinkBidiOverrideIsRefused() {
        guard case .deny = TerminalLinkPolicy.decide(origin: .hyperlink, raw: "https://example.com/\u{202E}gpj.exe") else {
            return XCTFail("expected deny for a target with a bidi override")
        }
    }

    // MARK: - Context-menu link detection

    func testFirstWebLinkTrimsProseWrappers() {
        XCTAssertEqual(
            GhosttyNSView.firstWebLink(in: ["[#1394](https://github.com/o/r/pull/1394)"])?.absoluteString,
            "https://github.com/o/r/pull/1394"
        )
        XCTAssertEqual(
            GhosttyNSView.firstWebLink(in: ["<https://example.com/x>"])?.absoluteString,
            "https://example.com/x"
        )
        XCTAssertEqual(
            GhosttyNSView.firstWebLink(in: ["https://example.com/x)."])?.absoluteString,
            "https://example.com/x"
        )
    }

    func testFirstWebLinkSkipsNonLinksAndKeepsOrderOfTheRest() {
        XCTAssertEqual(
            GhosttyNSView.firstWebLink(in: ["apps/desktop/src/main.rs", "see", "https://example.com/a", "https://other.example/b"])?.absoluteString,
            "https://example.com/a"
        )
    }

    func testFirstWebLinkRejectsOtherSchemes() {
        XCTAssertNil(GhosttyNSView.firstWebLink(in: ["mailto:dev@example.com"]))
        XCTAssertNil(GhosttyNSView.firstWebLink(in: ["file:///tmp/x.txt"]))
        XCTAssertNil(GhosttyNSView.firstWebLink(in: ["github.com/owner/repo/pull/1"]))
    }
}
