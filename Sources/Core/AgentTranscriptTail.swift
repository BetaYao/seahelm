import Foundation

/// Reads an agent's prose out of its own transcript file as the file grows.
///
/// Hooks carry tool calls and the turn's final message, but not the text an
/// agent writes between tool calls — the part that says what it is doing and
/// why. Claude Code and Codex append every message to a JSONL transcript whose
/// path arrives with each hook, so the timeline takes that prose from there.
final class AgentTranscriptTail {
    struct Entry: Equatable {
        enum Kind: Equatable { case text, thinking }
        let kind: Kind
        let text: String
        let timestamp: Date?
    }

    /// How much of a transcript seen for the first time is read. A long session
    /// is not replayed wholesale — only its recent end, and only what is newer
    /// than the caller's `since`.
    private let firstReadBytes: UInt64
    private var offsets: [String: UInt64] = [:]
    private let lock = NSLock()

    init(firstReadBytes: UInt64 = 256_000) {
        self.firstReadBytes = firstReadBytes
    }

    /// Assistant prose appended to `path` since the previous call for it, in file
    /// order. The first call for a path — or one after the file was replaced by a
    /// shorter one — returns only entries stamped after `since`.
    func newProse(path: String, since: Date) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }

        let known = offsets[path].flatMap { $0 <= size ? $0 : nil }
        let start = known ?? (size > firstReadBytes ? size - firstReadBytes : 0)
        guard start < size else {
            offsets[path] = size
            return []
        }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(size - start)),
              let lastNewline = data.lastIndex(of: 0x0A) else {
            // Nothing complete yet: a line still being written is read next time.
            offsets[path] = start
            return []
        }
        offsets[path] = start + UInt64(data.distance(from: data.startIndex, to: lastNewline) + 1)

        var body = data[data.startIndex..<lastNewline]
        if known == nil, start > 0, let cut = body.firstIndex(of: 0x0A) {
            body = body[body.index(after: cut)...]          // the window began mid-line
        }
        return body.split(separator: 0x0A).compactMap { line -> Entry? in
            guard let entry = Self.prose(line: Data(line)) else { return nil }
            if known == nil {
                guard let stamp = entry.timestamp, stamp > since else { return nil }
            }
            return entry
        }
    }

    /// The assistant prose in one transcript line, if it has any.
    ///
    ///     Claude Code  {"type":"assistant","message":{"content":[{"type":"text","text":…}]}}
    ///                  {"type":"assistant","message":{"content":[{"type":"thinking","thinking":…}]}}
    ///     Codex        {"type":"response_item","payload":{"type":"message","role":"assistant",
    ///                   "content":[{"type":"output_text","text":…}]}}
    ///                  {"type":"response_item","payload":{"type":"reasoning",
    ///                   "summary":[{"type":"summary_text","text":…}]}}
    ///
    /// Thinking is kept apart from what the agent says. Where the terminal shows it
    /// at all it narrates progress between tool calls; where it is redacted the
    /// block is empty and yields nothing. A subagent's lines (`isSidechain`) are its
    /// own conversation, not this pane's.
    static func prose(line: Data) -> Entry? {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        let said: [String], thought: [String]
        if obj["type"] as? String == "assistant", obj["isSidechain"] as? Bool != true,
           let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] {
            said = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            thought = content.filter { $0["type"] as? String == "thinking" }.compactMap { $0["thinking"] as? String }
        } else if obj["type"] as? String == "response_item", let payload = obj["payload"] as? [String: Any] {
            switch payload["type"] as? String {
            case "message" where payload["role"] as? String == "assistant":
                said = (payload["content"] as? [[String: Any]] ?? [])
                    .filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }
                thought = []
            case "reasoning":
                said = []
                thought = (payload["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            default:
                return nil
            }
        } else {
            return nil
        }
        let stamp = (obj["timestamp"] as? String).flatMap(parseDate)
        // Same cleaning the Stop hook's final message gets, so the two compare equal.
        let text = StopHookResponder.stripSentinel(from: said.joined(separator: "\n"))
        if !text.isEmpty { return Entry(kind: .text, text: text, timestamp: stamp) }
        let thinking = thought.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !thinking.isEmpty { return Entry(kind: .thinking, text: thinking, timestamp: stamp) }
        return nil
    }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole = ISO8601DateFormatter()

    private static func parseDate(_ s: String) -> Date? {
        fractional.date(from: s) ?? whole.date(from: s)
    }
}
