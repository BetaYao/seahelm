import Foundation

/// Every pane's message timeline, as seahelm-core keeps it
/// (`crates/core-messages`, docs/app-reads-core.md). The app keeps none of its
/// own: calls are the core's `message.snapshot` / `history` / `replay`, and
/// live messages come from one `message.subscribe` stream, fanned out here.
/// Calls block (a socket round trip): off main.
final class CoreMessages {
    static let shared = CoreMessages()

    private let lock = NSLock()
    private var subscribers: [Int: (MessageEvent) -> Void] = [:]
    private var nextToken = 0
    private var thread: Thread?

    func snapshot(paneId: String?) -> [MessageEvent] {
        var params: [String: Any] = [:]
        if let paneId { params["pane_id"] = paneId }
        guard case .success(let r) = CoreSocketClient.call("message.snapshot", params) else { return [] }
        return (r["messages"] as? [[String: Any]] ?? []).compactMap(MessageEvent.init(dict:))
    }

    // The first page also fills gaps between the core's independent snapshot budgets.
    // Those rows can be newer than beforeSeq; preserve sequence order when merging.
    func history(paneId: String, beforeSeq: UInt64, limit: Int) -> (events: [MessageEvent], hasMore: Bool) {
        guard case .success(let r) = CoreSocketClient.call(
            "message.history", ["pane_id": paneId, "before_seq": beforeSeq, "limit": limit]) else { return ([], false) }
        return ((r["messages"] as? [[String: Any]] ?? []).compactMap(MessageEvent.init(dict:)),
                r["has_more"] as? Bool ?? false)
    }

    /// What happened since `seq`; nil when the gap is unknown (start over).
    /// `truncated` names timelines that may have lost part of the gap.
    func replay(after seq: UInt64) -> (events: [MessageEvent], truncated: [String])? {
        guard case .success(let r) = CoreSocketClient.call("message.replay", ["after_seq": seq]),
              let replay = r["replay"] as? [String: Any] else { return nil }
        return ((replay["messages"] as? [[String: Any]] ?? []).compactMap(MessageEvent.init(dict:)),
                replay["truncated"] as? [String] ?? [])
    }

    /// Live messages, on the stream's thread. The first subscriber starts it.
    @discardableResult
    func subscribe(_ handler: @escaping (MessageEvent) -> Void) -> Int {
        lock.lock()
        nextToken += 1
        let token = nextToken
        subscribers[token] = handler
        let start = thread == nil
        if start {
            let t = Thread { [weak self] in self?.run() }
            t.name = "seahelm-core-messages"
            thread = t
        }
        let t = thread
        lock.unlock()
        if start { t?.start() }
        return token
    }

    func unsubscribe(_ token: Int) {
        lock.lock(); subscribers.removeValue(forKey: token); lock.unlock()
    }

    private func run() {
        var after: UInt64?
        var pause: TimeInterval = 1
        while true {
            if let fd = CoreSocketClient.open(timeout: 60) {
                after = follow(fd, after: after) ?? after
                close(fd)
                pause = 1
            }
            Thread.sleep(forTimeInterval: pause)
            pause = min(pause * 2, 10)
        }
    }

    /// One connection, resuming after the last message seen. Returns the
    /// last seq it delivered.
    private func follow(_ fd: Int32, after: UInt64?) -> UInt64? {
        var params: [String: Any] = [:]
        if let after { params["after_seq"] = after }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "message.subscribe", "params": params]
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        data.append(0x0A)
        guard data.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == data.count else { return nil }
        var last = after
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return last }
            pending.append(contentsOf: buffer[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if let result = obj["result"] as? [String: Any], last == nil {
                    last = (result["seq"] as? NSNumber)?.uint64Value
                }
                guard obj["method"] as? String == "message", let p = obj["params"] as? [String: Any],
                      let event = MessageEvent(dict: p) else { continue }
                last = event.seq
                lock.lock(); let handlers = Array(subscribers.values); lock.unlock()
                for h in handlers { h(event) }
            }
        }
    }
}
