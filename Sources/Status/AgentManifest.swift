import Foundation

// MARK: - Agent Manifest (JSON, one file per agent)
//
// Schema mirrors herdr's per-agent TOML manifest (AgentManifest / ManifestRule),
// expressed as zero-dependency JSON. Rules are evaluated against a region of the
// terminal snapshot; the highest-priority matching rule wins. `skip_state_update`
// rules suppress a state change without overwriting.
//
// Two seahelm-specific extensions herdr keeps Rust-side are declared here so they
// are configurable per agent: `process` (process-tree identification) and
// `authority` (which signal source is the state authority for the pane).
//
// Precedence when loading: ~/.config/seahelm/agents/<id>.json (user override)
// wins over the bundled Sources/Status/Manifests/<id>.json.

/// The detection-engine version this build understands. A manifest declaring a
/// higher `min_engine_version` is rejected (forward-compat guard, like herdr).
let MANIFEST_ENGINE_VERSION = 1

// Safety limits (copied from herdr) — enforced after decode; over-limit → rejected.
private let MAX_RULES_PER_MANIFEST = 128
private let MAX_GATE_DEPTH = 8
private let MAX_TOTAL_GATES = 512
private let MAX_MATCHER_CHARS = 512

struct AgentManifest: Codable {
    let id: String
    var version: String = ""
    var minEngineVersion: Int = 1
    var aliases: [String] = []
    var defaultStatus: String = "idle"
    var messageSkipPatterns: [String] = []
    var rules: [ManifestRule] = []

    // seahelm extensions (not present in herdr manifests)
    var process: ProcessMatch? = nil
    var authority: String = "session_only"   // session_only | full_lifecycle | screen_only

    enum CodingKeys: String, CodingKey {
        case id, version, aliases, rules, process, authority
        case minEngineVersion = "min_engine_version"
        case defaultStatus = "default_status"
        case messageSkipPatterns = "message_skip_patterns"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        minEngineVersion = try c.decodeIfPresent(Int.self, forKey: .minEngineVersion) ?? 1
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        defaultStatus = try c.decodeIfPresent(String.self, forKey: .defaultStatus) ?? "idle"
        messageSkipPatterns = try c.decodeIfPresent([String].self, forKey: .messageSkipPatterns) ?? []
        rules = try c.decodeIfPresent([ManifestRule].self, forKey: .rules) ?? []
        process = try c.decodeIfPresent(ProcessMatch.self, forKey: .process)
        authority = try c.decodeIfPresent(String.self, forKey: .authority) ?? "session_only"
    }
}

/// Process-tree identification hints (seahelm extension). Replaces screen-text
/// agent-type detection: match a pane's foreground process group members by
/// executable name or argv, penetrating generic runtimes (node → codex).
struct ProcessMatch: Codable {
    var execNames: [String] = []       // argv0 basename equals one of these
    var argvContains: [String] = []    // any argv token contains one of these (wrapper penetration)
    var genericRuntimes: [String] = [] // if argv0 is one of these, keep drilling into children
    var envHint: String? = nil         // env var whose value forces this agent id

    enum CodingKeys: String, CodingKey {
        case execNames = "exec_names"
        case argvContains = "argv_contains"
        case genericRuntimes = "generic_runtimes"
        case envHint = "env_hint"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        execNames = try c.decodeIfPresent([String].self, forKey: .execNames) ?? []
        argvContains = try c.decodeIfPresent([String].self, forKey: .argvContains) ?? []
        genericRuntimes = try c.decodeIfPresent([String].self, forKey: .genericRuntimes) ?? []
        envHint = try c.decodeIfPresent(String.self, forKey: .envHint)
    }
}

/// A rule = an inline MatchGate + result/metadata fields.
struct ManifestRule: Codable {
    let id: String
    let state: String
    var priority: Int = 0
    var region: String = "whole_recent"
    var skipStateUpdate: Bool = false
    var visibleIdle: Bool = false
    var visibleBlocker: Bool = false
    var visibleWorking: Bool = false

    // inline MatchGate
    var contains: [String] = []
    var regex: [String] = []
    var lineRegex: [String] = []
    var all: [MatchGate] = []
    var any: [MatchGate] = []
    var not: [MatchGate] = []

    enum CodingKeys: String, CodingKey {
        case id, state, priority, region, contains, regex, all, any, not
        case skipStateUpdate = "skip_state_update"
        case visibleIdle = "visible_idle"
        case visibleBlocker = "visible_blocker"
        case visibleWorking = "visible_working"
        case lineRegex = "line_regex"
    }

    var gate: MatchGate {
        MatchGate(contains: contains, regex: regex, lineRegex: lineRegex,
                  all: all, any: any, not: not)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        state = try c.decode(String.self, forKey: .state)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? "whole_recent"
        skipStateUpdate = try c.decodeIfPresent(Bool.self, forKey: .skipStateUpdate) ?? false
        visibleIdle = try c.decodeIfPresent(Bool.self, forKey: .visibleIdle) ?? false
        visibleBlocker = try c.decodeIfPresent(Bool.self, forKey: .visibleBlocker) ?? false
        visibleWorking = try c.decodeIfPresent(Bool.self, forKey: .visibleWorking) ?? false
        contains = try c.decodeIfPresent([String].self, forKey: .contains) ?? []
        regex = try c.decodeIfPresent([String].self, forKey: .regex) ?? []
        lineRegex = try c.decodeIfPresent([String].self, forKey: .lineRegex) ?? []
        all = try c.decodeIfPresent([MatchGate].self, forKey: .all) ?? []
        any = try c.decodeIfPresent([MatchGate].self, forKey: .any) ?? []
        not = try c.decodeIfPresent([MatchGate].self, forKey: .not) ?? []
    }
}

/// Recursive boolean gate. Same matcher fields as a rule's inline matcher.
struct MatchGate: Codable {
    var contains: [String] = []
    var regex: [String] = []
    var lineRegex: [String] = []
    var all: [MatchGate] = []
    var any: [MatchGate] = []
    var not: [MatchGate] = []

    enum CodingKeys: String, CodingKey {
        case contains, regex, all, any, not
        case lineRegex = "line_regex"
    }

    init(contains: [String] = [], regex: [String] = [], lineRegex: [String] = [],
         all: [MatchGate] = [], any: [MatchGate] = [], not: [MatchGate] = []) {
        self.contains = contains; self.regex = regex; self.lineRegex = lineRegex
        self.all = all; self.any = any; self.not = not
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contains = try c.decodeIfPresent([String].self, forKey: .contains) ?? []
        regex = try c.decodeIfPresent([String].self, forKey: .regex) ?? []
        lineRegex = try c.decodeIfPresent([String].self, forKey: .lineRegex) ?? []
        all = try c.decodeIfPresent([MatchGate].self, forKey: .all) ?? []
        any = try c.decodeIfPresent([MatchGate].self, forKey: .any) ?? []
        not = try c.decodeIfPresent([MatchGate].self, forKey: .not) ?? []
    }
}

// MARK: - Region

/// A slice of the terminal snapshot a rule matches against (copied from herdr).
enum ManifestRegion: Equatable {
    case wholeRecent
    case afterLastHorizontalRule
    case promptBoxBody
    case afterLastPromptMarker
    case beforeCurrentPromptMarker
    case bottomLines(Int)
    case bottomNonEmptyLines(Int)
    case oscTitle
    case oscProgress

    init(_ raw: String) {
        let parts = raw.split(separator: ":", maxSplits: 1)
        let head = parts.first.map(String.init) ?? "whole_recent"
        let arg = parts.count > 1 ? Int(parts[1]) : nil
        switch head {
        case "bottom_lines":                 self = .bottomLines(arg ?? 10)
        case "bottom_non_empty_lines":        self = .bottomNonEmptyLines(arg ?? 10)
        case "after_last_horizontal_rule":    self = .afterLastHorizontalRule
        case "prompt_box_body":               self = .promptBoxBody
        case "after_last_prompt_marker":      self = .afterLastPromptMarker
        case "before_current_prompt_marker":  self = .beforeCurrentPromptMarker
        case "osc_title":                     self = .oscTitle
        case "osc_progress":                  self = .oscProgress
        default:                              self = .wholeRecent
        }
    }
}

// MARK: - Validation

extension AgentManifest {
    enum ValidationError: Error, Equatable {
        case engineTooNew(Int)
        case tooManyRules(Int)
        case gateTooDeep
        case tooManyGates(Int)
        case matcherTooLong
    }

    /// Reject manifests that are incompatible or exceed safety limits.
    func validated() throws -> AgentManifest {
        guard minEngineVersion <= MANIFEST_ENGINE_VERSION else {
            throw ValidationError.engineTooNew(minEngineVersion)
        }
        guard rules.count <= MAX_RULES_PER_MANIFEST else {
            throw ValidationError.tooManyRules(rules.count)
        }
        var totalGates = 0
        for rule in rules {
            try Self.walk(rule.gate, depth: 0, totalGates: &totalGates)
        }
        return self
    }

    private static func walk(_ gate: MatchGate, depth: Int, totalGates: inout Int) throws {
        guard depth <= MAX_GATE_DEPTH else { throw ValidationError.gateTooDeep }
        for m in gate.contains + gate.regex + gate.lineRegex where m.count > MAX_MATCHER_CHARS {
            throw ValidationError.matcherTooLong
        }
        for sub in gate.all + gate.any + gate.not {
            totalGates += 1
            guard totalGates <= MAX_TOTAL_GATES else { throw ValidationError.tooManyGates(totalGates) }
            try walk(sub, depth: depth + 1, totalGates: &totalGates)
        }
    }
}

// MARK: - Status mapping

extension SailorStatus {
    /// Parse a manifest `state` string, accepting herdr's vocabulary
    /// (working/blocked) and our own (running/waiting), case-insensitively.
    static func fromManifest(_ raw: String) -> SailorStatus {
        switch raw.lowercased() {
        case "working", "running":  return .running
        case "blocked", "waiting":  return .waiting
        case "idle":                return .idle
        case "error":               return .error
        case "exited":              return .exited
        default:                    return .unknown
        }
    }
}
