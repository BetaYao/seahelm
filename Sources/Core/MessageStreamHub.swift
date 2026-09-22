import Foundation

/// Append-only per-pane message timeline projected from AgentRegistry ingest.
/// Does not write back into PaneInfo.
///
/// Rings are keyed by `MessageEvent.ringKey` and persisted, so a relaunch — which
/// during development is every `run.sh` — does not leave every idle pane empty.
/// Memory holds only the recent tail each client is sent on connect; the longer
/// history stays on disk and is paged in by `history`.
final class MessageStreamHub {
    /// Unit tests run inside the app and drive AgentRegistry with made-up panes;
    /// they must not leave those in the user's history.
    static let shared = MessageStreamHub(
        store: NSClassFromString("XCTestCase") == nil
            ? MessageStreamStore(directory: MessageStreamStore.defaultDirectory) : nil)

    private let lock = NSLock()
    private var subscribers: [Int: (MessageEvent) -> Void] = [:]
    private var nextToken = 0
    private var rings: [String: [MessageEvent]] = [:]
    private var coalesceByPane: [String: PaneMessageProjector.CoalesceState] = [:]
    private var nextSeq: UInt64 = 0
    private let perPaneCap: Int
    private let store: MessageStreamStore?

    init(store: MessageStreamStore? = nil, perPaneCap: Int = 80) {
        self.store = store
        self.perPaneCap = perPaneCap
        guard let store else { return }
        // `seq` carries on from the highest number on disk rather than restarting,
        // so the numbers a client pages history by mean the same thing tomorrow.
        rings = store.loadTails(count: perPaneCap)
        nextSeq = rings.values.compactMap { $0.last?.seq }.max() ?? 0
    }

    /// Project an ingest outcome and append resulting events.
    func ingest(outcome: IngestOutcome, config: MessageConfig = .default) {
        let paneId = outcome.info.id
        lock.lock()
        let coal = coalesceByPane[paneId] ?? .empty
        lock.unlock()

        let (events, next) = PaneMessageProjector.project(
            outcome: outcome, config: config, coalesce: coal)

        lock.lock()
        coalesceByPane[paneId] = next
        lock.unlock()

        append(events)
    }

    func append(_ events: [MessageEvent]) {
        guard !events.isEmpty else { return }
        lock.lock()
        var stamped: [MessageEvent] = []
        stamped.reserveCapacity(events.count)
        for var ev in events {
            var ring = rings[ev.ringKey] ?? []
            // A turn's final message reaches us twice — read from the transcript
            // and carried by the Stop hook — in whichever order they land.
            if ev.kind == .assistant,
               ring.filter({ $0.kind == .assistant }).suffix(3).contains(where: { $0.text == ev.text }) {
                continue
            }
            nextSeq += 1
            ev.seq = nextSeq
            ring.append(ev)
            if ring.count > perPaneCap {
                ring.removeFirst(ring.count - perPaneCap)
            }
            rings[ev.ringKey] = ring
            store?.save(ev)
            stamped.append(ev)
        }
        let subs = Array(subscribers.values)
        lock.unlock()
        for ev in stamped {
            for s in subs { s(ev) }
        }
    }

    /// One pane's ring, addressed by pane session key or station id; every ring
    /// when `paneId` is nil.
    func snapshot(paneId: String?) -> [MessageEvent] {
        lock.lock(); defer { lock.unlock() }
        if let paneId {
            return rings[ringKey(for: paneId)] ?? []
        }
        return rings.values.flatMap { $0 }.sorted { $0.seq < $1.seq }
    }

    /// Up to `limit` events of one pane older than `beforeSeq`, oldest first, and
    /// whether anything older still remains.
    func history(paneId: String, beforeSeq: UInt64, limit: Int) -> (events: [MessageEvent], hasMore: Bool) {
        lock.lock()
        let key = ringKey(for: paneId)
        let ring = rings[key] ?? []
        lock.unlock()
        if let store {
            return store.history(key: key, beforeSeq: beforeSeq, limit: limit)
        }
        let older = ring.filter { $0.seq < beforeSeq }
        return (Array(older.suffix(limit)), older.count > limit)
    }

    func eventsAfter(_ seq: UInt64) -> [MessageEvent] {
        lock.lock(); defer { lock.unlock() }
        return rings.values.flatMap { $0 }.filter { $0.seq > seq }.sorted { $0.seq < $1.seq }
    }

    /// The pane is gone for good (closed, worktree deleted) — drop its history,
    /// on disk too. Quitting the app never lands here.
    func clear(paneId: String, paneSessionKey: String? = nil) {
        lock.lock()
        let keys = rings.filter { key, ring in
            key == paneId || key == paneSessionKey || ring.contains { $0.paneId == paneId }
        }.map(\.key)
        for key in keys { rings.removeValue(forKey: key) }
        coalesceByPane.removeValue(forKey: paneId)
        lock.unlock()
        for key in keys { store?.remove(key: key) }
    }

    func subscribe(_ handler: @escaping (MessageEvent) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        let token = nextToken; nextToken += 1
        subscribers[token] = handler
        return token
    }

    func unsubscribe(_ token: Int) {
        lock.lock(); subscribers.removeValue(forKey: token); lock.unlock()
    }

    /// Callers hold `lock`. A station id resolves to its ring through the events
    /// it stamped; anything else is taken as the key itself.
    private func ringKey(for paneId: String) -> String {
        if rings[paneId] != nil { return paneId }
        return rings.first { $0.value.contains { $0.paneId == paneId } }?.key ?? paneId
    }
}

/// Disk side of `MessageStreamHub`: one JSONL file per ring under
/// `~/.config/seahelm/message-stream/`, oldest line first. Writes go through a
/// serial queue so the main-thread ingest path never waits on the disk.
final class MessageStreamStore {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/seahelm/message-stream", isDirectory: true)
    }

    private let dir: URL
    /// Events kept per pane. The file grows past it by half before being cut
    /// back, so a busy pane is not a rewrite per tool call.
    private let keep: Int
    private let queue = DispatchQueue(label: "seahelm.message-stream.store")
    /// Lines currently in each file. Touched only on `queue`.
    private var linesOnDisk: [String: Int] = [:]

    init(directory: URL, keep: Int = 2000) {
        dir = directory
        self.keep = keep
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// The newest `count` events of every persisted ring, oldest first. Only
    /// those lines are decoded; the rest of each file is just counted.
    func loadTails(count: Int) -> [String: [MessageEvent]] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        var rings: [String: [MessageEvent]] = [:]
        var counts: [String: Int] = [:]
        for url in files where url.pathExtension == "jsonl" {
            let lines = Self.lines(of: url)
            let events = lines.suffix(count).compactMap(Self.decode)
            guard let key = events.last?.ringKey else { continue }
            rings[key] = events
            counts[key] = lines.count
        }
        queue.sync { linesOnDisk = counts }
        return rings
    }

    func save(_ event: MessageEvent) {
        let key = event.ringKey
        queue.async {
            self.appendLine(event, key: key)
            let lines = (self.linesOnDisk[key] ?? 0) + 1
            self.linesOnDisk[key] = lines
            if lines > self.keep + self.keep / 2 { self.trim(key: key) }
        }
    }

    /// Reads after every queued write has landed, walking back from the newest
    /// line and decoding only what it returns.
    func history(key: String, beforeSeq: UInt64, limit: Int) -> (events: [MessageEvent], hasMore: Bool) {
        queue.sync { () -> (events: [MessageEvent], hasMore: Bool) in
            var older: [MessageEvent] = []
            for line in Self.lines(of: fileURL(key)).reversed() {
                guard let event = Self.decode(line), event.seq < beforeSeq else { continue }
                if older.count == limit { return (Array(older.reversed()), true) }
                older.append(event)
            }
            return (Array(older.reversed()), false)
        }
    }

    func remove(key: String) {
        queue.async {
            self.linesOnDisk.removeValue(forKey: key)
            try? FileManager.default.removeItem(at: self.fileURL(key))
        }
    }

    /// Blocks until every queued write has landed.
    func waitForWrites() {
        queue.sync {}
    }

    private func fileURL(_ key: String) -> URL {
        let safe = key.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" }
        return dir.appendingPathComponent(String(safe) + ".jsonl")
    }

    private static func lines(of url: URL) -> [Substring] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
    }

    /// Unreadable lines are skipped rather than failing the whole ring.
    private static func decode(_ line: Substring) -> MessageEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let dict = obj as? [String: Any] else { return nil }
        guard var event = MessageEvent(dict: dict) else { return nil }
        // Rows written before `UserPromptText` existed: a background task
        // finishing, recorded as though the user had typed it, and prompts
        // still wearing Claude Code's paste wrapper. Applying the same rule on
        // the way back out heals a history someone already has instead of
        // making them wait for the ring to roll over. Both readers — the replay
        // on launch and the scroll-back page — come through here.
        if event.kind == .user {
            guard let shown = UserPromptText.humanText(event.text ?? "") else { return nil }
            event.text = shown
        }
        return event
    }

    private func appendLine(_ event: MessageEvent, key: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: event.dict) else { return }
        let line = data + Data("\n".utf8)
        let url = fileURL(key)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    private func trim(key: String) {
        let url = fileURL(key)
        let kept = Self.lines(of: url).suffix(keep)
        try? Data(kept.map { $0 + "\n" }.joined().utf8).write(to: url, options: .atomic)
        linesOnDisk[key] = kept.count
    }
}

#if DEBUG
extension MessageStreamHub {
    /// The stored-row rule, reachable without a file: what a persisted line
    /// turns back into (nil when it is dropped on the way out).
    static func decodeForTests(_ dict: [String: Any]) -> MessageEvent? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let line = String(data: data, encoding: .utf8) else { return nil }
        return MessageStreamStore.decodeForTests(Substring(line))
    }
}

extension MessageStreamStore {
    static func decodeForTests(_ line: Substring) -> MessageEvent? { decode(line) }
}
#endif
