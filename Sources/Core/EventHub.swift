import Foundation

/// Fan-out broker for control-API event subscribers (mirrors herdr's EventHub).
/// ShipLog publishes one event per ingest here; any number of socket subscribers
/// receive them. A bounded ring buffer keyed by the monotonic ingest `seq` lets a
/// reconnecting subscriber replay what it missed via `events_after`.
final class EventHub {
    static let shared = EventHub()

    private let lock = NSLock()
    private var subscribers: [Int: (UInt64, [String: Any]) -> Void] = [:]
    private var nextToken = 0
    private var ring: [(seq: UInt64, event: [String: Any])] = []
    private let ringCap = 500

    /// Broadcast an event stamped with its ingest sequence. Subscribers are
    /// invoked outside the lock so a handler may (indirectly) re-enter the hub.
    func publish(seq: UInt64, event: [String: Any]) {
        lock.lock()
        ring.append((seq, event))
        if ring.count > ringCap { ring.removeFirst(ring.count - ringCap) }
        let subs = Array(subscribers.values)
        lock.unlock()
        for s in subs { s(seq, event) }
    }

    /// Register a subscriber; returns a token for `unsubscribe`.
    func subscribe(_ handler: @escaping (UInt64, [String: Any]) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        let token = nextToken; nextToken += 1
        subscribers[token] = handler
        return token
    }

    func unsubscribe(_ token: Int) {
        lock.lock(); subscribers.removeValue(forKey: token); lock.unlock()
    }

    /// Buffered events with seq strictly greater than `seq` (for replay).
    func eventsAfter(_ seq: UInt64) -> [(seq: UInt64, event: [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        return ring.filter { $0.seq > seq }
    }

    var currentSeq: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return ring.last?.seq ?? 0
    }

    #if DEBUG
    func resetForTesting() {
        lock.lock(); subscribers.removeAll(); ring.removeAll(); nextToken = 0; lock.unlock()
    }
    #endif
}
