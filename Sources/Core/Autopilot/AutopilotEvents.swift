import Foundation

/// Something that may wake First Mate. Produced by the triggers, matched to
/// rules by `AutopilotEngine`; it does nothing on its own.
struct AutopilotEvent: Equatable {
    let trigger: AutomationTrigger
    let repoPath: String
    let worktreePath: String
    let branch: String
    let pr: WorktreePRStatus?
    /// The worktree as seahelm measured it when the event fired.
    var facts: WorktreeFacts? = nil
}

/// A worktree's branch and PR, as one look at the fleet found them.
struct PRObservation: Equatable {
    let worktreePath: String
    let repoPath: String
    let branch: String
    let pr: WorktreePRStatus?
}

/// Turns successive PR snapshots into `ci.failed` / `pr.merged` events.
///
/// `ci.failed` fires on an observed edge only — checks that were not failing
/// and now are. A PR already red when seahelm first sees it (at launch, or a
/// worktree just added) is somebody's known state, not news, and waking an
/// agent for it on every relaunch would be noise.
///
/// `pr.merged` fires the first time a merge is seen, even at launch: cleanup
/// is what a merge asks for whenever it happened, and the merged set is
/// persisted (`AutopilotLedger`) so it fires once per PR, ever.
struct PREventDetector {
    private(set) var last: [String: WorktreePRStatus] = [:]

    mutating func observe(_ observations: [PRObservation],
                          alreadyMerged: (String) -> Bool) -> [AutopilotEvent] {
        var events: [AutopilotEvent] = []
        var next: [String: WorktreePRStatus] = [:]
        for o in observations {
            guard let pr = o.pr else { continue }
            next[o.worktreePath] = pr
            let event = { (trigger: AutomationTrigger) in
                AutopilotEvent(trigger: trigger, repoPath: o.repoPath, worktreePath: o.worktreePath,
                               branch: o.branch, pr: pr)
            }
            if pr.state == .merged {
                if !alreadyMerged(AutopilotLedger.mergedKey(repoPath: o.repoPath, pr: pr.number)) {
                    events.append(event(.prMerged))
                }
                continue
            }
            if pr.isLive, pr.checks == .failing, let old = last[o.worktreePath],
               old.number != pr.number || old.checks != .failing {
                events.append(event(.ciFailed))
            }
        }
        last = next
        return events
    }
}

/// Persisted memory of what has fired: merges already handled, and attempts
/// per rule, PR and day (`max_attempts`). Lives beside First Mate's state.
final class AutopilotLedger {
    struct State: Codable, Equatable {
        var merged: Set<String> = []
        /// day ("2026-11-03") → "rule|repo#pr" → count. Only today is kept.
        var attempts: [String: [String: Int]] = [:]
    }

    private let path: String
    private let lock = NSLock()
    private var state: State

    init(path: String) {
        self.path = path
        state = (try? Data(contentsOf: URL(fileURLWithPath: path)))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    static func mergedKey(repoPath: String, pr: Int) -> String { "\(repoPath)#\(pr)" }

    func hasHandledMerge(_ key: String) -> Bool { lock.withLock { state.merged.contains(key) } }

    func markMergeHandled(_ key: String) {
        lock.withLock { state.merged.insert(key) }
        save()
    }

    func attempts(rule: String, repoPath: String, pr: Int, day: String) -> Int {
        lock.withLock { state.attempts[day]?["\(rule)|\(repoPath)#\(pr)"] ?? 0 }
    }

    func recordAttempt(rule: String, repoPath: String, pr: Int, day: String) {
        lock.withLock {
            state.attempts = state.attempts.filter { $0.key == day }
            state.attempts[day, default: [:]]["\(rule)|\(repoPath)#\(pr)", default: 0] += 1
        }
        save()
    }

    private func save() {
        let snapshot = lock.withLock { state }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// What First Mate is handed for one matched rule.
struct AutopilotDispatch: Equatable {
    let rule: AutomationRule
    let event: AutopilotEvent
    let prompt: String
}

/// Matches events to a repo's rules and writes the prompt. Pure apart from the
/// ledger it is given.
enum AutopilotEngine {
    static func dispatches(for event: AutopilotEvent, config: AutomationConfig,
                           ledger: AutopilotLedger, day: String) -> [AutopilotDispatch] {
        var out: [AutopilotDispatch] = []
        for rule in config.rules(for: event.trigger) {
            if let filter = rule.branch, !filter.matches(event.branch) { continue }
            if let max = rule.maxAttempts, let pr = event.pr,
               ledger.attempts(rule: rule.name, repoPath: event.repoPath, pr: pr.number, day: day) >= max {
                continue
            }
            out.append(AutopilotDispatch(rule: rule, event: event,
                                         prompt: prompt(rule: rule, event: event, config: config)))
        }
        return out
    }

    /// `{{name}}` → value. Unknown names are left as written, so a typo shows.
    static func render(_ template: String, event: AutopilotEvent, rule: AutomationRule) -> String {
        let values: [String: String] = [
            "repo": event.repoPath,
            "worktree": event.worktreePath,
            "branch": event.branch,
            "pr": event.pr.map { String($0.number) } ?? "",
            "pr_url": event.pr?.url ?? "",
            "rule": rule.name,
        ]
        var text = template
        for (key, value) in values { text = text.replacingOccurrences(of: "{{\(key)}}", with: value) }
        return text
    }

    /// A header First Mate can parse at a glance, then the rule's own words.
    static func prompt(rule: AutomationRule, event: AutopilotEvent, config: AutomationConfig) -> String {
        var lines = ["[seahelm event] \(event.trigger.eventName) · rule \(rule.name)",
                     "repo: \(event.repoPath)",
                     "worktree: \(event.worktreePath) (branch \(event.branch))"]
        if let pr = event.pr { lines.append("PR: #\(pr.number) \(pr.url) — \(pr.summary)") }
        if let facts = event.facts {
            lines.append("facts (measured by seahelm; trust these over your own summary): \(facts.summary)")
        }
        let autonomy = AutopilotAction.allCases
            .map { "\($0.rawValue)=\(config.autonomy(for: $0, rule: rule).rawValue)" }
            .joined(separator: ", ")
        lines.append("autonomy: \(autonomy)")
        lines.append("")
        lines.append(render(rule.brief, event: event, rule: rule).trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n")
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// One line per event, delivery and action: `audit.jsonl` beside the ledger.
/// What First Mate's view and the ⎈ marks are drawn from.
final class AutopilotAudit {
    struct Entry: Codable, Equatable {
        enum Kind: String, Codable {
            case event, delivered, queued, skipped, action, approval, denied, message
        }
        let at: Date
        let kind: Kind
        var rule: String?
        var worktreePath: String?
        var pr: Int?
        var action: String?
        var level: String?
        var text: String
    }

    private let path: String
    private let lock = NSLock()
    var onAppend: ((Entry) -> Void)?

    init(path: String) { self.path = path }

    func append(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        lock.withLock {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
                try? handle.close()
            } else {
                try? line.write(to: url)
            }
        }
        onAppend?(entry)
    }

    /// The newest `limit` entries, oldest first.
    func recent(limit: Int = 200) -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let text = lock.withLock({ try? String(contentsOfFile: path, encoding: .utf8) }) else { return [] }
        return text.split(separator: "\n").suffix(limit).compactMap {
            try? decoder.decode(Entry.self, from: Data($0.utf8))
        }
    }
}
