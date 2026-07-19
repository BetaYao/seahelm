import Foundation
import CryptoKit

/// Reads Cursor chat titles from `~/.cursor/chats/<md5(cwd)>/<chatId>/meta.json`.
///
/// Cursor (IDE + `cursor-agent`) stores a `title` + `cwd` per chat. Seahelm's
/// Claude-only `SessionTitleLookup` never sees these, so Cursor panes fell through
/// to pwd/branch even after many turns.
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
            guard let meta = readMeta(metaURL) else { continue }
            // Bucket is already md5(worktreePath); prefer exact cwd when present.
            if !meta.cwd.isEmpty, meta.cwd != worktreePath { continue }
            guard let title = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            let date = meta.updatedAt ?? ((try? metaURL.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
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
        let metaURL = chatsRoot
            .appendingPathComponent(md5Hex(worktreePath), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("meta.json")
        guard let meta = readMeta(metaURL),
              let title = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        return title
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

    // MARK: - Private

    private struct Meta {
        let title: String?
        let cwd: String
        let updatedAt: Date?
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
}
