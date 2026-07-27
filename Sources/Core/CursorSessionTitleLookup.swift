import Foundation
import CryptoKit
import SQLite3

/// Reads Cursor chat titles from `~/.cursor/chats/<md5(cwd)>/<chatId>/`.
///
/// Cursor stores each chat in its own directory under a bucket named
/// `md5(cwd)`, but the *title* lives in one of two places depending on which
/// client wrote the chat:
///
///   - **Cursor IDE** writes `meta.json` with a `title` key.
///   - **`cursor-agent` (the CLI)** writes `meta.json` *without* a title and
///     keeps the name in `store.db` — table `meta`, row `key = '0'`, whose
///     `value` is hex-encoded JSON carrying `{"agentId":…,"name":…}`.
///
/// Reading only `meta.json` therefore missed every CLI pane, which is why
/// Cursor Agent panes fell through to branch/path titles (issue #20). Both
/// sources are consulted here, `meta.json` first.
///
/// The chat directory name is the CLI's own `session_id` (it equals `agentId`
/// in `store.db`), so a per-pane lookup by session id is exact and two Cursor
/// panes in one worktree cannot swap titles.
enum CursorSessionTitleLookup {
    /// Most recently updated titled chat whose `cwd` matches `worktreePath`.
    static func title(
        worktreePath: String,
        fileManager: FileManager = .default,
        chatsRoot: URL = defaultChatsRoot()
    ) -> String? {
        guard !worktreePath.isEmpty else { return nil }
        let dir = chatsRoot.appendingPathComponent(md5Hex(worktreePath), isDirectory: true)
        guard let chats = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var best: (date: Date, title: String)?
        for chatDir in chats {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: chatDir.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            let metaURL = chatDir.appendingPathComponent("meta.json")
            let meta = readMeta(metaURL)
            // Bucket is already md5(worktreePath); prefer exact cwd when present.
            if let cwd = meta?.cwd, !cwd.isEmpty, cwd != worktreePath { continue }
            guard let title = chatTitle(in: chatDir, meta: meta) else { continue }
            let date = meta?.updatedAt ?? modified(metaURL) ?? modified(storeURL(chatDir)) ?? .distantPast
            if best == nil || date > best!.date {
                best = (date, title)
            }
        }
        return best?.title
    }

    /// Title for one chat id under the worktree's chat bucket.
    static func title(
        worktreePath: String,
        sessionId: String,
        fileManager: FileManager = .default,
        chatsRoot: URL = defaultChatsRoot()
    ) -> String? {
        guard !worktreePath.isEmpty, !sessionId.isEmpty else { return nil }
        guard !sessionId.contains("/"), !sessionId.hasPrefix(".") else { return nil }
        let chatDir = chatsRoot
            .appendingPathComponent(md5Hex(worktreePath), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        return chatTitle(in: chatDir, meta: readMeta(chatDir.appendingPathComponent("meta.json")))
    }

    static func md5Hex(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func defaultChatsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
    }

    /// Names Cursor assigns before it has generated a real one. Showing these
    /// would be worse than the branch fallback — every fresh Cursor pane in the
    /// window would read "New Agent".
    static func isPlaceholderTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty
            || normalized == "new agent"
            || normalized == "new chat"
            || normalized == "untitled"
    }

    // MARK: - Private

    private struct Meta {
        let title: String?
        let cwd: String
        let updatedAt: Date?
    }

    /// `meta.json`'s title if Cursor IDE wrote one, else the CLI's `store.db` name.
    private static func chatTitle(in chatDir: URL, meta: Meta?) -> String? {
        if let title = usable(meta?.title) { return title }
        return usable(storeName(storeURL(chatDir)))
    }

    private static func usable(_ raw: String?) -> String? {
        guard let title = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, !isPlaceholderTitle(title) else { return nil }
        return title
    }

    private static func storeURL(_ chatDir: URL) -> URL {
        chatDir.appendingPathComponent("store.db")
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func readMeta(_ url: URL) -> Meta? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let title = obj["title"] as? String
        let cwd = (obj["cwd"] as? String) ?? ""
        let updatedAt: Date?
        if let ms = obj["updatedAtMs"] as? Double {
            updatedAt = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = obj["updatedAtMs"] as? Int {
            updatedAt = Date(timeIntervalSince1970: Double(ms) / 1000)
        } else {
            updatedAt = nil
        }
        return Meta(title: title, cwd: cwd, updatedAt: updatedAt)
    }

    // MARK: - store.db

    /// `name` from `store.db`, memoized on (size, mtime) so the per-poll title
    /// resolve doesn't reopen SQLite while the chat is untouched — and picks the
    /// new name the moment `cursor-agent` renames the chat mid-session.
    private static func storeName(_ url: URL) -> String? {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]))
            .flatMap { values -> Stamp? in
                guard let date = values.contentModificationDate else { return nil }
                return Stamp(modified: date, size: values.fileSize ?? 0)
            }
        guard let stamp else { return nil }

        cacheLock.lock()
        if let hit = cache[url.path], hit.stamp == stamp {
            cacheLock.unlock()
            return hit.name
        }
        cacheLock.unlock()

        let name = readStoreName(url)
        cacheLock.lock()
        cache[url.path] = (stamp, name)
        cacheLock.unlock()
        return name
    }

    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }

    private static var cache: [String: (stamp: Stamp, name: String?)] = [:]
    private static let cacheLock = NSLock()

    /// Open the chat store read-only and pull `meta['0'].name`.
    ///
    /// The CLI may hold the database open, so this must never block on it: the
    /// connection is read-only with a short busy timeout, and every failure path
    /// simply yields nil (the caller falls back to `meta.json` / branch).
    private static func readStoreName(_ url: URL) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM meta WHERE key = '0' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        return name(fromStoreValue: String(cString: raw))
    }

    /// The stored value is hex-encoded JSON. Plain JSON is accepted too, so a
    /// future Cursor schema that drops the hex wrapper keeps working.
    static func name(fromStoreValue value: String) -> String? {
        let candidates = [hexDecoded(value), Data(value.utf8)].compactMap { $0 }
        for data in candidates {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = obj["name"] as? String {
                return name
            }
        }
        return nil
    }

    private static func hexDecoded(_ hex: String) -> Data? {
        let scalars = Array(hex.utf8)
        guard scalars.count % 2 == 0, !scalars.isEmpty else { return nil }
        var data = Data(capacity: scalars.count / 2)
        var index = 0
        while index < scalars.count {
            guard let high = nibble(scalars[index]), let low = nibble(scalars[index + 1]) else {
                return nil
            }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
