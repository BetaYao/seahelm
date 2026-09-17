import Foundation

/// Append-only per-pane message timeline projected from AgentRegistry ingest.
/// Does not write back into PaneInfo.
final class MessageStreamHub {
    static let shared = MessageStreamHub()

    private let lock = NSLock()
    private var subscribers: [Int: (MessageEvent) -> Void] = [:]
    private var nextToken = 0
    private var rings: [String: [MessageEvent]] = [:]
    private var coalesceByPane: [String: PaneMessageProjector.CoalesceState] = [:]
    private var nextSeq: UInt64 = 0
    private let perPaneCap = 80

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
            nextSeq += 1
            ev.seq = nextSeq
            var ring = rings[ev.paneId] ?? []
            ring.append(ev)
            if ring.count > perPaneCap {
                ring.removeFirst(ring.count - perPaneCap)
            }
            rings[ev.paneId] = ring
            stamped.append(ev)
        }
        let subs = Array(subscribers.values)
        lock.unlock()
        for ev in stamped {
            for s in subs { s(ev) }
        }
    }

    func snapshot(paneId: String?) -> [MessageEvent] {
        lock.lock(); defer { lock.unlock() }
        if let paneId {
            return rings[paneId] ?? []
        }
        return rings.values.flatMap { $0 }.sorted { $0.seq < $1.seq }
    }

    func eventsAfter(_ seq: UInt64) -> [MessageEvent] {
        lock.lock(); defer { lock.unlock() }
        return rings.values.flatMap { $0 }.filter { $0.seq > seq }.sorted { $0.seq < $1.seq }
    }

    func clear(paneId: String) {
        lock.lock()
        rings.removeValue(forKey: paneId)
        coalesceByPane.removeValue(forKey: paneId)
        lock.unlock()
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

    #if DEBUG
    func resetForTesting() {
        lock.lock()
        subscribers.removeAll()
        rings.removeAll()
        coalesceByPane.removeAll()
        nextSeq = 0
        nextToken = 0
        lock.unlock()
    }
    #endif
}
