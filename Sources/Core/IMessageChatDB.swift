import Foundation
import SQLite3

/// One inbound row from `~/Library/Messages/chat.db`.
struct IMessageRow {
    let rowId: Int64
    /// GUID of the message — stable, used as `InboundMessage.messageId`.
    let guid: String
    /// Sender handle: `+8613800138000` or an Apple ID.
    let sender: String
    /// `chat.guid`, e.g. `iMessage;-;+8613800138000` or `iMessage;+;chat123…`.
    let chatGuid: String?
    let isGroup: Bool
    let text: String
    let date: Date
}

/// Read-only incremental reader over the Messages database.
///
/// There is no public API for receiving iMessages, so this is the only way in.
/// Two consequences shape the whole type:
///
/// 1. The app needs **Full Disk Access** — `~/Library/Messages` is TCC-protected
///    and no entitlement or prompt can substitute. `open()` failing with
///    "unable to open database file" is almost always a missing grant, not a
///    missing file, so `probe()` reports that case separately.
/// 2. Messages.app owns this database. We open it `mode=ro` and never write,
///    including no checkpointing — reading a live WAL is fine, corrupting a
///    user's message history would not be.
final class IMessageChatDB {
    enum ProbeResult: Equatable {
        case ok
        case missing
        /// Present but unreadable — the Full Disk Access case.
        case denied(String)
    }

    static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db").path

    /// Seconds between the Apple epoch (2001-01-01) and the Unix epoch.
    private static let appleEpochOffset: TimeInterval = 978_307_200

    private let path: String
    private var db: OpaquePointer?

    init(path: String = IMessageChatDB.defaultPath) {
        self.path = path
    }

    deinit { close() }

    // MARK: - Lifecycle

    /// Attempt to open read-only. Distinguishes "no Messages history" from
    /// "TCC said no" because the two need completely different user guidance.
    func probe() -> ProbeResult {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        if db != nil { return .ok }
        do {
            try open()
            return .ok
        } catch {
            return .denied(error.localizedDescription)
        }
    }

    func open() throws {
        guard db == nil else { return }
        var handle: OpaquePointer?
        // `immutable=0`: the file is live and Messages is writing to it; we want
        // sqlite to honour the WAL rather than assume a frozen snapshot.
        let uri = "file:\(path)?mode=ro&immutable=0"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(uri, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(rc)"
            sqlite3_close(handle)
            throw NSError(domain: "IMessageChatDB", code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        sqlite3_busy_timeout(handle, 2000)
        db = handle
    }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    // MARK: - Queries

    /// Highest message ROWID currently in the database — the cursor to start
    /// from so enabling the bridge doesn't replay old texts as commands.
    func maxRowId() -> Int64 {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT IFNULL(MAX(ROWID), 0) FROM message", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Incoming messages with `ROWID > afterRowId`, oldest first.
    ///
    /// `text` is NULL on macOS 13+ for most messages — the body moved into
    /// `attributedBody`, an NSKeyedArchiver blob — so both columns are selected
    /// and `IMessageBodyDecoder` picks whichever has content.
    func fetchIncoming(afterRowId: Int64, limit: Int = 50) -> [IMessageRow] {
        guard let db else { return [] }
        let sql = """
        SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date,
               h.id AS handle_id, c.guid AS chat_guid, c.style
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE m.ROWID > ? AND m.is_from_me = 0
        ORDER BY m.ROWID ASC
        LIMIT ?
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("[iMessage] prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        sqlite3_bind_int64(stmt, 1, afterRowId)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var rows: [IMessageRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            guard let guidC = sqlite3_column_text(stmt, 1) else { continue }
            let guid = String(cString: guidC)

            let plain = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            var blob: Data?
            if let bytes = sqlite3_column_blob(stmt, 3) {
                blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 3)))
            }
            guard let body = IMessageBodyDecoder.decode(text: plain, attributedBody: blob),
                  !body.isEmpty else { continue }

            // Apple stores nanoseconds since 2001-01-01 (seconds in very old rows).
            let raw = sqlite3_column_double(stmt, 4)
            let seconds = raw > 1e11 ? raw / 1e9 : raw
            let date = Date(timeIntervalSince1970: seconds + Self.appleEpochOffset)

            let sender = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let chatGuid = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            // chat.style: 43 = group, 45 = one-on-one.
            let isGroup = sqlite3_column_int(stmt, 7) == 43

            rows.append(IMessageRow(rowId: rowId, guid: guid, sender: sender,
                                    chatGuid: chatGuid, isGroup: isGroup,
                                    text: body, date: date))
        }
        return rows
    }
}

// MARK: - Body decoding

enum IMessageBodyDecoder {
    /// Returns the message body, preferring the plain `text` column and falling
    /// back to unarchiving `attributedBody`.
    /// Nil rather than "" when nothing survives sanitizing — an attachment-only
    /// message carries no command and shouldn't reach the router at all.
    static func decode(text: String?, attributedBody: Data?) -> String? {
        if let text, let cleaned = nonEmpty(sanitize(text)) {
            return cleaned
        }
        guard let attributedBody else { return nil }
        return decodeAttributedBody(attributedBody).map(sanitize).flatMap(nonEmpty)
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    /// `attributedBody` is a *non*-secure NSKeyedArchiver archive of an
    /// NSAttributedString whose class graph includes NSMutableAttributedString
    /// and friends, so `NSKeyedUnarchiver.unarchivedObject(ofClass:)` (secure
    /// coding) rejects it. The deprecated non-secure path is the one that works.
    private static func decodeAttributedBody(_ data: Data) -> String? {
        if let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) {
            unarchiver.requiresSecureCoding = false
            if let attr = unarchiver.decodeObject(of: NSAttributedString.self, forKey: NSKeyedArchiveRootObjectKey) {
                return attr.string
            }
            if let obj = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSAttributedString {
                return obj.string
            }
        }
        return scavengeString(data)
    }

    /// Last resort for archives whose class graph the runtime refuses: the body
    /// sits in the archive as a length-prefixed UTF-8 run right after the
    /// `NSString` marker. Crude, but it beats dropping the message — and a
    /// dropped command looks to the user like the bridge is broken.
    private static func scavengeString(_ data: Data) -> String? {
        guard let marker = "NSString".data(using: .utf8),
              let range = data.range(of: marker) else { return nil }
        var idx = range.upperBound
        // Skip the class-name terminator and the archiver's type byte.
        while idx < data.count, data[idx] < 0x20 { idx += 1 }
        guard idx < data.count else { return nil }

        var length = Int(data[idx])
        idx += 1
        if length == 0x81 {  // 1-byte marker → 16-bit length follows, little-endian
            guard idx + 1 < data.count else { return nil }
            length = Int(data[idx]) | Int(data[idx + 1]) << 8
            idx += 2
        } else if length > 0x80 {
            return nil
        }
        guard length > 0, idx + length <= data.count else { return nil }
        return String(data: data.subdata(in: idx..<(idx + length)), encoding: .utf8)
    }

    /// Messages substitutes U+FFFC (object replacement) for inline attachments
    /// and wraps some bodies in U+FFFD; neither means anything as a command.
    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{fffc}", with: "")
            .replacingOccurrences(of: "\u{fffd}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
