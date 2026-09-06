import Foundation

/// Reads Claude Code's auto-generated session title (the `summary` record) for a
/// given worktree. Claude stores sessions under
/// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`, where `<encoded-cwd>` is
/// the absolute path with `/` and `.` replaced by `-`.
enum SessionTitleLookup {
    /// Title from the most recently modified session JSONL in the worktree's
    /// project directory, or nil if none has a `summary` record.
    /// - Parameter synchronously: read the transcript on this thread instead of
    ///   answering from the cache and scanning in the background. Only for
    ///   callers that cannot use a value that lands a moment later, and never
    ///   from the main thread — see `scanQueue`.
    static func title(
        worktreePath: String,
        fileManager: FileManager = .default,
        projectsRoot: URL = defaultProjectsRoot(),
        synchronously: Bool = false
    ) -> String? {
        guard !worktreePath.isEmpty else { return nil }
        let dir = projectsRoot.appendingPathComponent(
            encodedProjectComponent(worktreePath: worktreePath), isDirectory: true
        )
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let sessions = entries
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }

        for session in sessions {
            if let summary = lastSummary(in: session, synchronously: synchronously) {
                return summary
            }
        }
        return nil
    }

    /// Title for one named session, rather than for whatever ran in the worktree
    /// last. Two agents sharing a worktree write two transcripts into the same
    /// directory, so `title(worktreePath:)` hands them both the same words —
    /// which is no use when the point of the listing is telling them apart.
    ///
    /// Returns nil when the transcript has no title record yet, and for agents
    /// that don't keep transcripts here at all (only Claude writes under
    /// ~/.claude/projects) — callers need a fallback either way.
    static func title(
        worktreePath: String,
        sessionId: String,
        fileManager: FileManager = .default,
        projectsRoot: URL = defaultProjectsRoot(),
        synchronously: Bool = false
    ) -> String? {
        guard !worktreePath.isEmpty, !sessionId.isEmpty else { return nil }
        // The id is a transcript stem, but it reaches us from a webhook payload:
        // keep a crafted one from walking out of the projects directory.
        guard !sessionId.contains("/"), !sessionId.hasPrefix(".") else { return nil }
        let url = projectsRoot
            .appendingPathComponent(encodedProjectComponent(worktreePath: worktreePath), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return lastSummary(in: url, synchronously: synchronously)
    }

    /// Encodes an absolute path the way Claude Code names its project directories.
    static func encodedProjectComponent(worktreePath: String) -> String {
        var result = ""
        for ch in worktreePath {
            result.append(ch == "/" || ch == "." ? "-" : ch)
        }
        return result
    }

    /// Memoized `lastSummary` results, keyed by path and stamped with the file's
    /// size + mtime. Transcripts routinely run to tens of megabytes and the pane
    /// title is resolved on every focus change, so re-reading one per click
    /// stalls the main thread — switching panes quickly visibly lagged the title.
    private static let summaryCacheLock = NSLock()
    private static var summaryCache: [String: (size: Int, mtime: Date, scannedAt: Date, summary: String?)] = [:]
    /// A transcript that is being written to changes every few seconds, which
    /// defeats the size + mtime stamp and had the whole file re-read on every
    /// call — the branch-refresh timer, every notification, every title-bar
    /// update — on the main thread, for as long as the agent kept talking. A
    /// title changes far more slowly than a transcript grows.
    static var rescanInterval: TimeInterval = 30

    /// Scans run here, never on the caller's thread.
    ///
    /// The stamp and the rescan window bound how *often* a transcript is read,
    /// but not what one read costs — and the caller is the main thread building
    /// a dashboard row or a window title, once per pane per repaint. Transcripts
    /// run to tens of megabytes (49MB in this fleet, 873MB across it) and a scan
    /// searches the whole file for three markers. Sampling the app found the
    /// main thread spending *all* of its time in exactly that, which starves
    /// everything that hops to main: `seahelm pane list` took 40s, and a
    /// Telegram command took 40s to answer.
    ///
    /// So `lastSummary` no longer reads anything. It answers from the cache and
    /// queues a rescan when the file has moved on. A title changes far more
    /// slowly than the transcript it is read from, so answering with the
    /// previous scan's words costs nothing real, and every caller repaints on a
    /// timer, which is what picks the new value up.
    private static let scanQueue = DispatchQueue(label: "com.seahelm.session-title", qos: .utility)
    /// Paths with a scan already queued, so a repaint storm queues one scan per
    /// file rather than one per call.
    private static var scansInFlight: Set<String> = []

    private static func lastSummary(in fileURL: URL, synchronously: Bool) -> String? {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = (values?.fileSize).flatMap { size in
            (values?.contentModificationDate).map { (size, $0) }
        }

        summaryCacheLock.lock()
        let hit = summaryCache[fileURL.path]
        summaryCacheLock.unlock()

        if let hit {
            // Byte-for-byte what was scanned: the cached answer is exact.
            if let stamp, hit.size == stamp.0, hit.mtime == stamp.1 { return hit.summary }
            // Moved on, but not long enough ago to be worth re-reading.
            if Date().timeIntervalSince(hit.scannedAt) < rescanInterval { return hit.summary }
        }

        if synchronously {
            let summary = readLastSummary(in: fileURL)
            summaryCacheLock.lock()
            summaryCache[fileURL.path] = (stamp?.0 ?? 0, stamp?.1 ?? .distantPast, Date(), summary)
            summaryCacheLock.unlock()
            return summary
        }

        scheduleScan(fileURL, stamp: stamp)
        // nil only until the first scan lands; every caller has a fallback.
        return hit?.summary
    }

    /// Reads the transcript on `scanQueue` and publishes it to the cache.
    /// Stamped with what the file looked like *before* the read, so anything
    /// appended while it ran is caught by the next rescan rather than being
    /// silently marked as already seen.
    private static func scheduleScan(_ fileURL: URL, stamp: (size: Int, mtime: Date)?) {
        let path = fileURL.path
        summaryCacheLock.lock()
        let alreadyQueued = scansInFlight.contains(path)
        if !alreadyQueued { scansInFlight.insert(path) }
        summaryCacheLock.unlock()
        guard !alreadyQueued else { return }

        scanQueue.async {
            let summary = readLastSummary(in: fileURL)
            summaryCacheLock.lock()
            // No stamp means the file could not be stat'd; record the scan time
            // anyway so a missing file does not spin the queue.
            summaryCache[path] = (stamp?.size ?? 0, stamp?.mtime ?? .distantPast, Date(), summary)
            scansInFlight.remove(path)
            summaryCacheLock.unlock()
        }
    }

    /// The byte patterns of the three title records. Searching the raw bytes
    /// for these, then parsing only the lines that carry one, is what makes a
    /// tens-of-megabytes transcript cheap to scan: the previous line-by-line
    /// walk spent its time in string searches over every line of the file.
    private static let titleMarkers: [(type: String, key: String, marker: Data)] = [
        ("custom-title", "customTitle", Data("\"type\":\"custom-title\"".utf8)),
        ("ai-title", "aiTitle", Data("\"type\":\"ai-title\"".utf8)),
        ("summary", "summary", Data("\"type\":\"summary\"".utf8)),
    ]

    private static func readLastSummary(in fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        // Newer Claude Code writes `ai-title` records (and `custom-title` when the
        // user renames a session in the resume picker); older versions wrote
        // `summary`. Track the last of each and prefer the user's own rename.
        var found: [String: String] = [:]
        for entry in titleMarkers {
            var searchFrom = data.startIndex
            var last: String?
            while searchFrom < data.endIndex,
                  let hit = data.range(of: entry.marker, in: searchFrom..<data.endIndex) {
                searchFrom = hit.upperBound
                // The marker can also sit inside a message body that quotes it;
                // only a line whose own `type` is the record counts.
                let line = data[lineRange(containing: hit.lowerBound, in: data)]
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["type"] as? String == entry.type,
                      let title = object[entry.key] as? String, !title.isEmpty else { continue }
                last = title
            }
            if let last { found[entry.type] = last }
        }
        return found["custom-title"] ?? found["ai-title"] ?? found["summary"]
    }

    private static func lineRange(containing index: Data.Index, in data: Data) -> Range<Data.Index> {
        var start = index
        while start > data.startIndex, data[start - 1] != 0x0A { start -= 1 }
        var end = index
        while end < data.endIndex, data[end] != 0x0A { end += 1 }
        return start..<end
    }

    private static func defaultProjectsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }
}
