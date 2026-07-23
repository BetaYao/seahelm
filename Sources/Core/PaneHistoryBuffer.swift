import Foundation

/// Per-pane message ring buffer with JSONL persistence, backing the MQTT
/// `history/request` reply (`docs/remote-clients-design.md` §15.3). The app
/// otherwise keeps only the *latest* message per pane (`SailorInfo.lastMessage`);
/// this accumulates a bounded recent history so a client can scroll back.
///
/// One append-only `<paneId>.jsonl` file per pane under
/// `~/.config/seahelm/history/`; the in-memory ring is the source of truth for
/// reads, the file is rewritten (trimmed) whenever the ring overflows.
final class PaneHistoryBuffer {
    private let dir: URL
    private let maxPerPane: Int
    private var mem: [String: [[String: Any]]] = [:]   // paneId → entries, oldest→newest
    private let lock = NSLock()

    init(directory: URL? = nil, maxPerPane: Int = 200) {
        if let directory {
            self.dir = directory
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.dir = home.appendingPathComponent(".config/seahelm/history", isDirectory: true)
        }
        self.maxPerPane = maxPerPane
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Append one message entry (`{seq, kind, text, …}`). Consecutive duplicates
    /// (same `text`) are dropped so a flickering status doesn't spam the feed.
    func append(paneId: String, entry: [String: Any]) {
        guard !paneId.isEmpty else { return }
        lock.lock()
        var list = mem[paneId] ?? loadLocked(paneId)
        if let last = list.last, (last["text"] as? String) == (entry["text"] as? String) {
            mem[paneId] = list
            lock.unlock()
            return
        }
        list.append(entry)
        let overflowed = list.count > maxPerPane
        if overflowed { list.removeFirst(list.count - maxPerPane) }
        mem[paneId] = list
        lock.unlock()

        if overflowed {
            rewrite(paneId, list)          // trim on disk too
        } else {
            appendLine(paneId, entry)      // cheap append
        }
    }

    /// Recent entries for a pane, oldest→newest, at most `limit`, optionally only
    /// those with `seq < beforeSeq` (paging). Returns `(messages, hasMore)`.
    func messages(paneId: String, limit: Int, beforeSeq: Int?) -> (messages: [[String: Any]], hasMore: Bool) {
        lock.lock(); defer { lock.unlock() }
        var list = mem[paneId] ?? loadLocked(paneId)
        if let beforeSeq {
            list = list.filter { ($0["seq"] as? Int ?? Int.max) < beforeSeq }
        }
        let window = Array(list.suffix(max(0, limit)))
        return (window, list.count > window.count)
    }

    // MARK: - Disk

    private func fileURL(_ paneId: String) -> URL {
        let safe = paneId.map { ("A"..."Z").contains($0) || ("a"..."z").contains($0)
            || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" ? $0 : "_" }
        return dir.appendingPathComponent(String(safe) + ".jsonl")
    }

    /// Load + trim from disk into memory (caller holds `lock`).
    private func loadLocked(_ paneId: String) -> [[String: Any]] {
        let url = fileURL(paneId)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            mem[paneId] = []
            return []
        }
        var list: [[String: Any]] = []
        for line in text.split(separator: "\n") {
            if let d = line.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                list.append(obj)
            }
        }
        if list.count > maxPerPane { list.removeFirst(list.count - maxPerPane) }
        mem[paneId] = list
        return list
    }

    private func appendLine(_ paneId: String, _ entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = fileURL(paneId)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.data(using: .utf8)?.write(to: url)   // first write
        }
    }

    private func rewrite(_ paneId: String, _ list: [[String: Any]]) {
        let lines = list.compactMap { entry -> String? in
            guard let d = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        let blob = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try? blob.data(using: .utf8)?.write(to: fileURL(paneId), options: .atomic)
    }
}
