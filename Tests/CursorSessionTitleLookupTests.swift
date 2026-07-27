import XCTest
import SQLite3
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

    // MARK: - cursor-agent CLI (store.db)

    func testTitleFromStoreDBWhenMetaHasNoTitle() throws {
        let wt = "/Users/me/proj"
        let bucket = root.appendingPathComponent(CursorSessionTitleLookup.md5Hex(wt), isDirectory: true)
        // What `cursor-agent` actually writes: meta.json without a title, and
        // the chat name only in store.db.
        try writeMeta(in: bucket, chatId: "cli-chat", title: nil, cwd: wt, updatedAtMs: 5)
        try writeStore(in: bucket, chatId: "cli-chat", name: "Fix the flaky test")

        XCTAssertEqual(
            CursorSessionTitleLookup.title(worktreePath: wt, sessionId: "cli-chat", chatsRoot: root),
            "Fix the flaky test"
        )
        XCTAssertEqual(
            CursorSessionTitleLookup.title(worktreePath: wt, chatsRoot: root),
            "Fix the flaky test"
        )
    }

    func testStoreDBRenameIsPickedUp() throws {
        let wt = "/Users/me/proj"
        let bucket = root.appendingPathComponent(CursorSessionTitleLookup.md5Hex(wt), isDirectory: true)
        try writeMeta(in: bucket, chatId: "cli-chat", title: nil, cwd: wt, updatedAtMs: 5)
        try writeStore(in: bucket, chatId: "cli-chat", name: "First Name")
        XCTAssertEqual(
            CursorSessionTitleLookup.title(worktreePath: wt, sessionId: "cli-chat", chatsRoot: root),
            "First Name"
        )

        try writeStore(in: bucket, chatId: "cli-chat", name: "Renamed Mid Session")
        XCTAssertEqual(
            CursorSessionTitleLookup.title(worktreePath: wt, sessionId: "cli-chat", chatsRoot: root),
            "Renamed Mid Session",
            "the store.db memo must invalidate when Cursor rewrites the chat"
        )
    }

    func testPlaceholderStoreNameFallsThrough() throws {
        let wt = "/Users/me/proj"
        let bucket = root.appendingPathComponent(CursorSessionTitleLookup.md5Hex(wt), isDirectory: true)
        try writeMeta(in: bucket, chatId: "fresh", title: nil, cwd: wt, updatedAtMs: 5)
        try writeStore(in: bucket, chatId: "fresh", name: "New Agent")

        XCTAssertNil(CursorSessionTitleLookup.title(worktreePath: wt, sessionId: "fresh", chatsRoot: root))
        XCTAssertNil(CursorSessionTitleLookup.title(worktreePath: wt, chatsRoot: root))
    }

    func testSiblingCliChatsDoNotCrossContaminate() throws {
        let wt = "/Users/me/proj"
        let bucket = root.appendingPathComponent(CursorSessionTitleLookup.md5Hex(wt), isDirectory: true)
        try writeMeta(in: bucket, chatId: "pane-a", title: nil, cwd: wt, updatedAtMs: 10)
        try writeStore(in: bucket, chatId: "pane-a", name: "Pane A Work")
        try writeMeta(in: bucket, chatId: "pane-b", title: nil, cwd: wt, updatedAtMs: 20)
        try writeStore(in: bucket, chatId: "pane-b", name: "Pane B Work")

        XCTAssertEqual(
            CursorSessionTitleLookup.title(worktreePath: wt, sessionId: "pane-a", chatsRoot: root),
            "Pane A Work"
        )
        XCTAssertEqual(
            CursorSessionTitleLookup.title(worktreePath: wt, sessionId: "pane-b", chatsRoot: root),
            "Pane B Work"
        )
    }

    func testMetaJSONTitleWinsOverStoreName() throws {
        let wt = "/Users/me/proj"
        let bucket = root.appendingPathComponent(CursorSessionTitleLookup.md5Hex(wt), isDirectory: true)
        try writeMeta(in: bucket, chatId: "both", title: "IDE Title", cwd: wt, updatedAtMs: 5)
        try writeStore(in: bucket, chatId: "both", name: "Store Name")

        XCTAssertEqual(
            CursorSessionTitleLookup.title(worktreePath: wt, sessionId: "both", chatsRoot: root),
            "IDE Title"
        )
    }

    func testStoreValueAcceptsHexAndPlainJSON() {
        let json = #"{"agentId":"x","name":"Hexed"}"#
        let hex = json.utf8.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(CursorSessionTitleLookup.name(fromStoreValue: hex), "Hexed")
        XCTAssertEqual(
            CursorSessionTitleLookup.name(fromStoreValue: #"{"name":"Plain"}"#), "Plain")
        XCTAssertNil(CursorSessionTitleLookup.name(fromStoreValue: "not json"))
    }

    // MARK: - Helpers

    private func writeMeta(in bucket: URL, chatId: String, title: String?, cwd: String, updatedAtMs: Int) throws {
        let dir = bucket.appendingPathComponent(chatId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var obj: [String: Any] = [
            "schemaVersion": 1,
            "cwd": cwd,
            "updatedAtMs": updatedAtMs,
        ]
        if let title { obj["title"] = title }
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: dir.appendingPathComponent("meta.json"))
    }

    /// Mirrors `cursor-agent`'s store: one `meta` row, key `'0'`, value = hex of
    /// the chat JSON.
    private func writeStore(in bucket: URL, chatId: String, name: String) throws {
        let dir = bucket.appendingPathComponent(chatId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("store.db")
        let json = try JSONSerialization.data(withJSONObject: ["agentId": chatId, "name": name])
        let hex = json.map { String(format: "%02x", $0) }.joined()

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in [
            "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)",
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('0', '\(hex)')",
        ] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
    }
}
