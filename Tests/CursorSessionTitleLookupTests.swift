import XCTest
@testable import seahelm

final class CursorSessionTitleLookupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-cursor-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTitlePicksNewestMatchingChat() throws {
        let wt = "/Users/me/proj"
        let bucket = root.appendingPathComponent(CursorSessionTitleLookup.md5Hex(wt), isDirectory: true)
        try writeMeta(in: bucket, chatId: "old", title: "Older", cwd: wt, updatedAtMs: 1_000)
        try writeMeta(in: bucket, chatId: "new", title: "Newer Title", cwd: wt, updatedAtMs: 2_000)

        XCTAssertEqual(
            CursorSessionTitleLookup.title(worktreePath: wt, chatsRoot: root),
            "Newer Title"
        )
    }

    func testTitleBySessionId() throws {
        let wt = "/Users/me/proj"
        let bucket = root.appendingPathComponent(CursorSessionTitleLookup.md5Hex(wt), isDirectory: true)
        try writeMeta(in: bucket, chatId: "abc-123", title: "Exact Chat", cwd: wt, updatedAtMs: 1)

        XCTAssertEqual(
            CursorSessionTitleLookup.title(worktreePath: wt, sessionId: "abc-123", chatsRoot: root),
            "Exact Chat"
        )
        XCTAssertNil(
            CursorSessionTitleLookup.title(worktreePath: wt, sessionId: "missing", chatsRoot: root)
        )
    }

    func testMd5MatchesKnownCursorBucket() {
        // Cursor keys chat buckets by md5(cwd) — keep stable so titles resolve.
        XCTAssertEqual(
            CursorSessionTitleLookup.md5Hex("/Users/liziliu/Documents/banana-git/saas-mono"),
            "bbcf5935e8845c2e4cef8ceea135e8af"
        )
    }

    private func writeMeta(in bucket: URL, chatId: String, title: String, cwd: String, updatedAtMs: Int) throws {
        let dir = bucket.appendingPathComponent(chatId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = [
            "schemaVersion": 1,
            "title": title,
            "cwd": cwd,
            "updatedAtMs": updatedAtMs,
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: dir.appendingPathComponent("meta.json"))
    }
}
