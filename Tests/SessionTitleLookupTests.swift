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
