import Foundation

/// Coalesces duplicate logical Telegram sends. A card can be rediscovered by
/// several status sources before the first HTTP request comes back; that must
/// remain one Telegram message, not a queue of identical cards.
final class TelegramPacketBook {
    enum Decision: Equatable {
        case send
        case joined
        case delivered(String?)
    }

    private struct Delivered {
        let messageID: String?
        let at: Date
    }

    private var inFlight: [String: [(String?) -> Void]] = [:]
    private var delivered: [String: Delivered] = [:]
    private let lock = NSLock()
    static let retention: TimeInterval = 60 * 60

    func begin(key: String, completion: ((String?) -> Void)?, now: Date = Date()) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        delivered = delivered.filter { now.timeIntervalSince($0.value.at) < Self.retention }
        if let prior = delivered[key] {
            return .delivered(prior.messageID)
        }
        if inFlight[key] != nil {
            if let completion { inFlight[key, default: []].append(completion) }
            return .joined
        }
        inFlight[key] = completion.map { [$0] } ?? []
        return .send
    }

    func finish(key: String, messageID: String?, now: Date = Date()) {
        lock.lock()
        let completions = inFlight.removeValue(forKey: key) ?? []
        // A failed packet should be allowed to try again on the next real
        // event; only a message Telegram accepted earns the retention entry.
        if messageID != nil { delivered[key] = Delivered(messageID: messageID, at: now) }
        lock.unlock()
        completions.forEach { $0(messageID) }
    }
}
