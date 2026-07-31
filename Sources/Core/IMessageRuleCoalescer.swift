import Foundation

/// Merges rule-triggered prompts that land on the same pane within a short
/// window, so a burst of related alerts (Aliyun 80% + 90% SMS in the same
/// second) becomes one agent turn instead of two overlapping ones.
///
/// Window is fixed from the *first* hit: later hits in the same bucket append
/// without sliding the deadline, so a noisy source can't delay forever.
final class IMessageRuleCoalescer {
    typealias Fire = (_ prompt: String, _ target: IMessageRuleTarget) -> Void
    typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    let window: TimeInterval
    private let schedule: Scheduler
    private let lock = NSLock()
    private var buckets: [String: Bucket] = [:]

    private struct Bucket {
        var target: IMessageRuleTarget
        var prompts: [String]
        var armed: Bool
    }

    init(window: TimeInterval = 30, scheduler: Scheduler? = nil) {
        self.window = window
        self.schedule = scheduler ?? { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Buffer `prompt` for `target`. The first hit on a key arms a one-shot
    /// timer; further hits only append. `onFire` runs once with the combined
    /// prompt when the window elapses.
    func enqueue(prompt: String,
                 target: IMessageRuleTarget,
                 ruleName: String,
                 onFire: @escaping Fire) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = Self.key(for: target)

        lock.lock()
        var bucket = buckets[key] ?? Bucket(target: target, prompts: [], armed: false)
        if !bucket.prompts.contains(trimmed) {
            bucket.prompts.append(trimmed)
        }
        let shouldArm = !bucket.armed
        if shouldArm { bucket.armed = true }
        let bufferedCount = bucket.prompts.count
        buckets[key] = bucket
        lock.unlock()

        guard shouldArm else {
            NSLog("[iMessage] Rule '\(ruleName)' coalesced into pending pane \(key) (\(bufferedCount) buffered)")
            return
        }

        NSLog("[iMessage] Rule '\(ruleName)' armed \(Int(window))s coalesce for pane \(key)")
        schedule(window) { [weak self] in
            self?.flush(key: key, onFire: onFire)
        }
    }

    /// Join buffered prompts. A single alert stays verbatim so existing rule
    /// templates keep their wording; a burst gets an explicit merge header.
    static func combine(_ prompts: [String]) -> String {
        let parts = prompts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = parts.first else { return "" }
        guard parts.count > 1 else { return first }

        var lines: [String] = ["收到 \(parts.count) 条告警（已合并），请一并排查："]
        for (index, part) in parts.enumerated() {
            lines.append("—— \(index + 1)/\(parts.count) ——\n\(part)")
        }
        return lines.joined(separator: "\n\n")
    }

    static func key(for target: IMessageRuleTarget) -> String {
        let value = target.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(target.kind.rawValue):\(value)"
    }

    private func flush(key: String, onFire: Fire) {
        lock.lock()
        guard let bucket = buckets.removeValue(forKey: key) else {
            lock.unlock()
            return
        }
        lock.unlock()

        let combined = Self.combine(bucket.prompts)
        guard !combined.isEmpty else { return }
        onFire(combined, bucket.target)
    }
}
