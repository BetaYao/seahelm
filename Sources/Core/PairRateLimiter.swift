import Foundation

final class PairRateLimiter {
    private let maxFailures: Int
    private let window: TimeInterval
    private let lock = NSLock()
    private var failures: [String: [Date]] = [:]

    init(maxFailures: Int = 5, window: TimeInterval = 60) {
        self.maxFailures = maxFailures
        self.window = window
    }

    func allow(ip: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        prune(ip: ip, now: now)
        return (failures[ip] ?? []).count < maxFailures
    }

    func recordFailure(ip: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        prune(ip: ip, now: now)
        failures[ip, default: []].append(now)
    }

    func recordSuccess(ip: String) {
        lock.lock(); defer { lock.unlock() }
        failures.removeValue(forKey: ip)
    }

    private func prune(ip: String, now: Date) {
        guard let list = failures[ip] else { return }
        let kept = list.filter { now.timeIntervalSince($0) < window }
        if kept.isEmpty { failures.removeValue(forKey: ip) }
        else { failures[ip] = kept }
    }
}
