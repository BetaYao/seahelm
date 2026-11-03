import Foundation
import Yams

/// What First Mate may do on its own. See docs/first-mate-autopilot.md §2.4.
enum AutopilotAction: String, CaseIterable, Codable {
    /// Type into another pane (`seahelm pane run/send`).
    case messagePane = "message_pane"
    /// A new worktree with an agent on it (`seahelm worktree create`).
    case startAgent = "start_agent"
    /// Remove a worktree (`seahelm worktree delete`).
    case deleteWorktree = "delete_worktree"
}

enum AutonomyLevel: String, Codable {
    case auto, ask, deny
}

/// A level per action. Missing entries fall back to `AutomationConfig.defaultAutonomy`.
typealias AutonomyMap = [AutopilotAction: AutonomyLevel]

enum AutomationTrigger: Equatable {
    case ciFailed
    case prMerged
    /// A cron expression. Parsed now, scheduled in phase 2.
    case schedule(String)

    var eventName: String {
        switch self {
        case .ciFailed: return "ci.failed"
        case .prMerged: return "pr.merged"
        case .schedule: return "schedule"
        }
    }
}

/// `when: { branch: … }`: an exact name, a glob (`feat/*`), or either negated
/// with a leading `!`.
struct BranchFilter: Equatable {
    let pattern: String

    func matches(_ branch: String) -> Bool {
        let negated = pattern.hasPrefix("!")
        let glob = negated ? String(pattern.dropFirst()) : pattern
        let hit = fnmatch(glob, branch, 0) == 0
        return negated ? !hit : hit
    }
}

struct AutomationRule: Equatable {
    var name: String
    var trigger: AutomationTrigger
    /// `enabled: false` keeps a rule written down without it firing.
    var branch: BranchFilter?
    /// Per PR per day. Nil = unlimited.
    var maxAttempts: Int?
    var autonomy: AutonomyMap = [:]
    var brief: String
    var enabled = true

    init(name: String, trigger: AutomationTrigger, branch: BranchFilter? = nil, maxAttempts: Int? = nil,
         autonomy: AutonomyMap = [:], brief: String, enabled: Bool = true) {
        self.name = name
        self.trigger = trigger
        self.branch = branch
        self.maxAttempts = maxAttempts
        self.autonomy = autonomy
        self.brief = brief
        self.enabled = enabled
    }
}

/// `"23:00-08:00"`: may wrap midnight.
struct QuietHours: Equatable {
    let startMinute: Int
    let endMinute: Int

    var text: String {
        String(format: "%02d:%02d-%02d:%02d", startMinute / 60, startMinute % 60, endMinute / 60, endMinute % 60)
    }

    init?(_ text: String) {
        let parts = text.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let start = Self.minute(parts[0]), let end = Self.minute(parts[1]) else { return nil }
        startMinute = start
        endMinute = end
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if startMinute == endMinute { return false }
        return startMinute < endMinute
            ? (m >= startMinute && m < endMinute)
            : (m >= startMinute || m < endMinute)
    }

    private static func minute(_ s: String) -> Int? {
        let hm = s.split(separator: ":")
        guard hm.count == 2, let h = Int(hm[0]), let m = Int(hm[1]), (0..<24).contains(h), (0..<60).contains(m)
        else { return nil }
        return h * 60 + m
    }
}

struct AutomationSettings: Equatable {
    var maxConcurrentAgents: Int?
    /// Percent of the Claude/Codex 5h window above which no agent is started.
    var pauseAboveUsage: Double?
    var quietHours: QuietHours?
}

/// One repo's `.seahelm/automations.yml`, or the built-in rules when it has none.
struct AutomationConfig: Equatable {
    static let relativePath = ".seahelm/automations.yml"

    var settings = AutomationSettings()
    var rules: [AutomationRule]
    /// What an action does when its rule says nothing: the user's global
    /// defaults (Settings ▸ First Mate), set by whoever loads the config.
    var defaults: AutonomyMap = defaultAutonomy

    /// What an action does when neither a rule nor the user says otherwise.
    static let defaultAutonomy: AutonomyMap = [
        .messagePane: .auto,
        .startAgent: .ask,
        .deleteWorktree: .ask,
    ]

    /// A repo without a file of its own gets these two.
    static let builtIn = AutomationConfig(rules: [
        AutomationRule(
            name: "fix-ci", trigger: .ciFailed, branch: BranchFilter(pattern: "!main"), maxAttempts: 2,
            autonomy: [.messagePane: .auto, .startAgent: .ask],
            brief: """
            PR #{{pr}} on {{branch}} failed CI. Read why with `gh run view --log-failed` \
            (or `gh pr checks {{pr}}`). If the worktree's agent is idle, tell it what broke and \
            ask it to fix and push; if it is busy, wait for it; if there is none, start one.
            """),
        AutomationRule(
            name: "cleanup-merged", trigger: .prMerged,
            autonomy: [.deleteWorktree: .ask],
            brief: """
            PR #{{pr}} ({{branch}}) has been merged. If the worktree has no uncommitted or \
            unpushed work and its panes are idle, delete it; otherwise say what is left.
            """),
    ])

    /// The level for `action` under `rule` (nil = a conversation, not a rule).
    func autonomy(for action: AutopilotAction, rule: AutomationRule?) -> AutonomyLevel {
        rule?.autonomy[action] ?? defaults[action] ?? Self.defaultAutonomy[action] ?? .ask
    }

    func rules(for trigger: AutomationTrigger) -> [AutomationRule] {
        rules.filter { rule in
            guard rule.enabled else { return false }
            switch (rule.trigger, trigger) {
            case (.ciFailed, .ciFailed), (.prMerged, .prMerged): return true
            case let (.schedule(a), .schedule(b)): return a == b
            default: return false
            }
        }
    }

    // MARK: - Parsing

    enum ParseError: Error, Equatable, LocalizedError {
        case notAMapping
        case rule(index: Int, message: String)
        case yaml(String)

        var errorDescription: String? {
            switch self {
            case .notAMapping: return "automations.yml must be a mapping with `rules:`"
            case let .rule(index, message): return "rule \(index + 1): \(message)"
            case let .yaml(message): return message
            }
        }
    }

    static func parse(yaml: String) throws -> AutomationConfig {
        let root: Any?
        do { root = try Yams.load(yaml: yaml) } catch { throw ParseError.yaml("\(error)") }
        guard let map = root as? [String: Any] else { throw ParseError.notAMapping }

        var settings = AutomationSettings()
        if let fm = map["first_mate"] as? [String: Any] {
            if let budget = fm["budget"] as? [String: Any] {
                settings.maxConcurrentAgents = budget["max_concurrent_agents"] as? Int
                settings.pauseAboveUsage = (budget["pause_above_usage"] as? Double)
                    ?? (budget["pause_above_usage"] as? Int).map(Double.init)
            }
            if let quiet = fm["quiet_hours"] as? String { settings.quietHours = QuietHours(quiet) }
        }

        let rawRules = map["rules"] as? [Any] ?? []
        var rules: [AutomationRule] = []
        for (i, raw) in rawRules.enumerated() {
            guard let r = raw as? [String: Any] else { throw ParseError.rule(index: i, message: "not a mapping") }
            guard let name = r["name"] as? String, !name.isEmpty else {
                throw ParseError.rule(index: i, message: "missing name")
            }
            let trigger: AutomationTrigger
            switch r["on"] {
            case "ci.failed" as String: trigger = .ciFailed
            case "pr.merged" as String: trigger = .prMerged
            case let on as [String: Any]:
                guard let cron = on["schedule"] as? String else {
                    throw ParseError.rule(index: i, message: "`on` mapping needs `schedule`")
                }
                trigger = .schedule(cron)
            default:
                throw ParseError.rule(index: i, message: "unknown `on` (ci.failed, pr.merged or {schedule: …})")
            }
            guard let brief = r["brief"] as? String, !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ParseError.rule(index: i, message: "missing brief") }

            var rule = AutomationRule(name: name, trigger: trigger, brief: brief)
            if let when = r["when"] as? [String: Any], let branch = when["branch"] as? String {
                rule.branch = BranchFilter(pattern: branch)
            }
            rule.maxAttempts = r["max_attempts"] as? Int
            rule.enabled = r["enabled"] as? Bool ?? true
            if let autonomy = r["autonomy"] as? [String: Any] {
                for (key, value) in autonomy {
                    guard let action = AutopilotAction(rawValue: key) else {
                        throw ParseError.rule(index: i, message: "unknown action `\(key)`")
                    }
                    guard let s = value as? String, let level = AutonomyLevel(rawValue: s) else {
                        throw ParseError.rule(index: i, message: "`\(key)` must be auto, ask or deny")
                    }
                    rule.autonomy[action] = level
                }
            }
            rules.append(rule)
        }
        return AutomationConfig(settings: settings, rules: rules)
    }

    // MARK: - Writing

    /// The file's text for this config. Written by Settings; a hand-written
    /// file's comments do not survive it, which the editor says before saving.
    func yaml() -> String {
        var root: [String: Any] = [:]
        var fm: [String: Any] = [:]
        var budget: [String: Any] = [:]
        if let n = settings.maxConcurrentAgents { budget["max_concurrent_agents"] = n }
        if let p = settings.pauseAboveUsage { budget["pause_above_usage"] = Int(p) }
        if !budget.isEmpty { fm["budget"] = budget }
        if let q = settings.quietHours { fm["quiet_hours"] = q.text }
        if !fm.isEmpty { root["first_mate"] = fm }
        root["rules"] = rules.map { rule -> [String: Any] in
            var r: [String: Any] = ["name": rule.name, "brief": rule.brief]
            switch rule.trigger {
            case .ciFailed: r["on"] = "ci.failed"
            case .prMerged: r["on"] = "pr.merged"
            case .schedule(let cron): r["on"] = ["schedule": cron]
            }
            if let branch = rule.branch { r["when"] = ["branch": branch.pattern] }
            if let max = rule.maxAttempts { r["max_attempts"] = max }
            if !rule.autonomy.isEmpty {
                r["autonomy"] = Dictionary(uniqueKeysWithValues: rule.autonomy.map { ($0.key.rawValue, $0.value.rawValue) })
            }
            if !rule.enabled { r["enabled"] = false }
            return r
        }
        let body = (try? Yams.dump(object: root, sortKeys: true)) ?? ""
        return "# First Mate rules — docs/first-mate-autopilot.md\n" + body
    }

    /// Write this config as the repo's file.
    func write(repoPath: String) throws {
        let path = (repoPath as NSString).appendingPathComponent(Self.relativePath)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try yaml().write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The defaults with the user's choices (Config's raw strings) laid over them.
    static func defaults(overriding raw: [String: String]) -> AutonomyMap {
        var map = defaultAutonomy
        for (key, value) in raw {
            if let action = AutopilotAction(rawValue: key), let level = AutonomyLevel(rawValue: value) {
                map[action] = level
            }
        }
        return map
    }

    /// Whether the repo has a file of its own (as opposed to the built-in rules).
    static func hasFile(repoPath: String) -> Bool {
        FileManager.default.fileExists(atPath: (repoPath as NSString).appendingPathComponent(relativePath))
    }

    /// The repo's own file, else the built-in rules. A file that does not parse
    /// is reported and stops the repo's automation rather than falling back:
    /// rules someone wrote and got wrong must not silently become the defaults.
    static func load(repoPath: String) -> (config: AutomationConfig?, error: String?) {
        let path = (repoPath as NSString).appendingPathComponent(relativePath)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return (builtIn, nil) }
        do { return (try parse(yaml: text), nil) } catch {
            return (nil, "\(relativePath): \(error.localizedDescription)")
        }
    }
}
