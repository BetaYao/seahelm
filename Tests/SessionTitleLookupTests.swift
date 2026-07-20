import XCTest
@testable import seahelm

final class SessionTitleLookupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-sessiontitle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func projectDir(for worktreePath: String) -> URL {
        let encoded = SessionTitleLookup.encodedProjectComponent(worktreePath: worktreePath)
        let dir = root.appendingPathComponent(encoded, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Transcripts are huge and the title is resolved on every pane focus change,
    /// so results are cached — but a rewritten transcript must still win.
    func testRereadsAfterTranscriptChanges() throws {
        let wt = "/Users/me/repo-worktrees/cache-x"
        let dir = projectDir(for: wt)
        let url = dir.appendingPathComponent("sess-1.jsonl")

        try #"{"type":"summary","summary":"Before"}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            SessionTitleLookup.title(worktreePath: wt, sessionId: "sess-1", projectsRoot: root),
            "Before"
        )
        // Cached read: same file, same answer, no reparse required.
        XCTAssertEqual(
            SessionTitleLookup.title(worktreePath: wt, sessionId: "sess-1", projectsRoot: root),
            "Before"
        )

        // Rewrite with different content and a distinct mtime.
        let newLines = [
            #"{"type":"summary","summary":"Before"}"#,
            #"{"type":"summary","summary":"After"}"#,
        ].joined(separator: "\n")
        try newLines.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path
        )

        XCTAssertEqual(
            SessionTitleLookup.title(worktreePath: wt, sessionId: "sess-1", projectsRoot: root),
            "After"
        )
    }

    func testReturnsLastSummary() throws {
        let wt = "/Users/me/repo-worktrees/feature-x"
        let dir = projectDir(for: wt)
        let lines = [
            #"{"type":"summary","summary":"First title"}"#,
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"summary","summary":"Refactor the parser"}"#,
        ].joined(separator: "\n")
        try lines.write(to: dir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let title = SessionTitleLookup.title(worktreePath: wt, projectsRoot: root)
        XCTAssertEqual(title, "Refactor the parser")
    }

    /// The whole point of the by-id lookup: two agents in one worktree write two
    /// transcripts side by side, and the worktree-keyed lookup would hand both of
    /// them whichever was touched last.
    func testTitleBySessionIdPicksThatSessionNotTheNewestOne() throws {
        let wt = "/Users/me/repo-worktrees/two-agents"
        let dir = projectDir(for: wt)
        try #"{"type":"ai-title","aiTitle":"Older agent"}"#
            .write(to: dir.appendingPathComponent("older.jsonl"), atomically: true, encoding: .utf8)
        try #"{"type":"ai-title","aiTitle":"Newer agent"}"#
            .write(to: dir.appendingPathComponent("newer.jsonl"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            SessionTitleLookup.title(worktreePath: wt, sessionId: "older", projectsRoot: root),
            "Older agent")
        XCTAssertEqual(
            SessionTitleLookup.title(worktreePath: wt, sessionId: "newer", projectsRoot: root),
            "Newer agent")
    }

    func testTitleBySessionIdMissesGracefully() throws {
        let wt = "/Users/me/repo-worktrees/none"
        _ = projectDir(for: wt)
        // No transcript: agents that keep no session file under ~/.claude land here.
        XCTAssertNil(SessionTitleLookup.title(worktreePath: wt, sessionId: "ghost", projectsRoot: root))
        // The id arrives from a webhook payload, so it must not walk out of the dir.
        XCTAssertNil(SessionTitleLookup.title(
            worktreePath: wt, sessionId: "../../escape", projectsRoot: root))
    }

    func testReturnsAITitleFromModernSessionFormat() throws {
        // Newer Claude Code stopped writing `summary` records; the session title
        // lives in `ai-title` records instead (regression: cards fell back to the
        // last prompt because only `summary` was parsed).
        let wt = "/Users/me/repo-worktrees/feature-ai"
        let dir = projectDir(for: wt)
        let lines = [
            #"{"type":"mode","mode":"normal","sessionId":"abc"}"#,
            #"{"type":"ai-title","aiTitle":"测试 all-in-one 本地部署","sessionId":"abc"}"#,
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
        ].joined(separator: "\n")
        try lines.write(to: dir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let title = SessionTitleLookup.title(worktreePath: wt, projectsRoot: root)
        XCTAssertEqual(title, "测试 all-in-one 本地部署")
    }

    func testCustomTitleWinsOverAITitle() throws {
        // A user rename (custom-title) beats the AI-generated title.
        let wt = "/Users/me/repo-worktrees/feature-custom"
        let dir = projectDir(for: wt)
        let lines = [
            #"{"type":"ai-title","aiTitle":"AI title"}"#,
            #"{"type":"custom-title","customTitle":"My name"}"#,
        ].joined(separator: "\n")
        try lines.write(to: dir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let title = SessionTitleLookup.title(worktreePath: wt, projectsRoot: root)
        XCTAssertEqual(title, "My name")
    }

    func testReturnsNilWhenNoSummary() throws {
        let wt = "/Users/me/repo-worktrees/feature-y"
        let dir = projectDir(for: wt)
        try #"{"type":"user","message":{"role":"user","content":"hi"}}"#
            .write(to: dir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        XCTAssertNil(SessionTitleLookup.title(worktreePath: wt, projectsRoot: root))
    }

    func testReturnsNilWhenDirMissing() {
        XCTAssertNil(SessionTitleLookup.title(worktreePath: "/nope/missing", projectsRoot: root))
    }

    func testEncodingReplacesSlashesAndDots() {
        XCTAssertEqual(
            SessionTitleLookup.encodedProjectComponent(worktreePath: "/Users/me/repo.app/feature"),
            "-Users-me-repo-app-feature"
        )
    }
}
