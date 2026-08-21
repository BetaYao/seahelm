import Foundation

// MARK: - Detection result

/// Rich detection output (mirrors herdr's AgentDetection). Carries the visible_*
/// flags used for publish gating / debounce bypass, plus the matched rule id for
/// explainability (`agent explain`).
struct Detection: Equatable {
    var state: AgentStatus
    var visibleIdle: Bool = false
    var visibleBlocker: Bool = false
    var visibleWorking: Bool = false
    var skipStateUpdate: Bool = false
    var matchedRuleId: String? = nil
    /// No rule matched — `state` is the manifest's `default_status` filling the
    /// gap, not something observed on screen. Callers must treat it as weaker
    /// than a matched rule: see `DebouncedStatusTracker.update`.
    var isDefaulted: Bool = false
    /// The session has background work of its own (a shell it launched, a monitor
    /// it is watching). Deliberately NOT a status: the agent can be parked at an
    /// empty prompt, ready for input, while this is true. Kept separate so the
    /// dashboard can still show the worktree as busy without the status axis
    /// losing the running → idle edge that notifications ride on.
    var backgroundBusy: Bool = false

    static let unknown = Detection(state: .unknown)
}

/// Inputs to the engine: the terminal snapshot plus retained OSC signals.
struct DetectionInput {
    var screen: String            // already lowercased by caller for `contains`
    var oscTitle: String = ""
    var oscProgress: String = ""
}

// MARK: - Compiled manifest

/// A manifest with its regexes compiled once. Rules are pre-sorted by descending
/// priority so evaluation stops at the first (highest-priority) match.
final class CompiledManifest {
    let manifest: AgentManifest
    private let compiledRules: [CompiledRule]
    /// Rules flagged `background_task` — evaluated on their own pass, never as
    /// candidates for the status decision.
    private let backgroundRules: [CompiledRule]

    struct CompiledRule {
        let rule: ManifestRule
        let region: ManifestRegion
        let gate: CompiledGate
    }

    init(_ manifest: AgentManifest) {
        self.manifest = manifest
        let compiled = manifest.rules
            .sorted { $0.priority > $1.priority }   // stable: ties keep source order
            .map { CompiledRule(rule: $0, region: ManifestRegion($0.region), gate: CompiledGate($0.gate)) }
        // Two independent questions, two rule sets. Priority orders the status
        // rules against each other; a background rule competes with nothing,
        // because "the session has a shell running" and "the agent is working"
        // are not answers to the same question and must not shadow one another.
        self.compiledRules = compiled.filter { !$0.rule.backgroundTask }
        self.backgroundRules = compiled.filter { $0.rule.backgroundTask }
    }

    /// Evaluate all rules; highest-priority match wins. Returns `.unknown`
    /// (falling through to default_status handling by the caller) if none match.
    ///
    /// `background_task` rules run on their own pass and only raise
    /// `backgroundBusy`: "this session has a shell running" answers a different
    /// question than "what is the agent doing". Letting one decide the status made
    /// a pane parked at an empty prompt read as running for as long as its monitor
    /// lived — and a pane that never leaves running never emits the edge that
    /// notifies.
    func evaluate(_ input: DetectionInput) -> Detection {
        let backgroundBusy = backgroundRules.contains {
            $0.gate.matches(Self.regionText($0.region, input))
        }
        for cr in compiledRules {
            let text = Self.regionText(cr.region, input)
            guard cr.gate.matches(text) else { continue }
            return Detection(
                state: AgentStatus.fromManifest(cr.rule.state),
                visibleIdle: cr.rule.visibleIdle,
                visibleBlocker: cr.rule.visibleBlocker,
                visibleWorking: cr.rule.visibleWorking,
                skipStateUpdate: cr.rule.skipStateUpdate,
                matchedRuleId: cr.rule.id,
                backgroundBusy: backgroundBusy
            )
        }
        return Detection(state: .unknown, backgroundBusy: backgroundBusy)
    }

    /// Default fallback when no rule matched a known agent.
    var defaultStatus: AgentStatus { AgentStatus.fromManifest(manifest.defaultStatus) }

    /// Explainability: the winning rule plus the evidence it matched on, or nil if
    /// no rule matched. Same evaluation order as `evaluate`.
    ///
    /// Evidence is narrowed to the single line responsible whenever one line is
    /// enough to satisfy the gate. Reporting the whole region instead is actively
    /// misleading — it reads as "the rule matched this footer" when the real match
    /// was some line of transcript higher up, which is exactly how a false
    /// `running` gets blamed on the wrong rule.
    func matchDetail(_ input: DetectionInput) -> (rule: ManifestRule, regionText: String)? {
        for cr in compiledRules {
            let text = Self.regionText(cr.region, input)
            guard cr.gate.matches(text) else { continue }
            return (cr.rule, Self.narrowEvidence(text, gate: cr.gate))
        }
        return nil
    }

    /// The first line that satisfies the gate on its own, else the region text.
    /// Only ever called from the explain path, so the extra passes are free.
    private static func narrowEvidence(_ text: String, gate: CompiledGate) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            if gate.matches(s) { return s.trimmingCharacters(in: .whitespaces) }
        }
        return text
    }

    // MARK: Region extraction

    private static func regionText(_ region: ManifestRegion, _ input: DetectionInput) -> String {
        switch region {
        case .oscTitle:    return input.oscTitle.lowercased()
        case .oscProgress: return input.oscProgress.lowercased()
        case .wholeRecent: return input.screen
        case .bottomLines(let n):
            return lastLines(input.screen, count: n, nonEmpty: false)
        case .bottomNonEmptyLines(let n):
            return lastLines(input.screen, count: n, nonEmpty: true)
        case .afterLastHorizontalRule:
            return afterLastHorizontalRule(input.screen)
        // The prompt-box / prompt-marker regions need shell/OSC133 marker context
        // we don't yet thread through here; fall back to whole_recent until the
        // OSC/prompt tracker lands (phase A5).
        case .promptBoxBody, .afterLastPromptMarker, .beforeCurrentPromptMarker:
            return input.screen
        }
    }

    private static func lastLines(_ text: String, count: Int, nonEmpty: Bool) -> String {
        var lines: [Substring] = []
        var idx = text.endIndex
        var lineEnd = text.endIndex
        while idx > text.startIndex && lines.count < count {
            idx = text.index(before: idx)
            if text[idx] == "\n" {
                let line = text[text.index(after: idx)..<lineEnd]
                if !nonEmpty || !line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    lines.append(line)
                }
                lineEnd = idx
            }
        }
        if lines.count < count && lineEnd > text.startIndex {
            let line = text[text.startIndex..<lineEnd]
            if !nonEmpty || !line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                lines.append(line)
            }
        }
        return lines.reversed().joined(separator: "\n")
    }

    private static func afterLastHorizontalRule(_ text: String) -> String {
        // A horizontal rule is a line made only of box-drawing/rule characters.
        let ruleChars: Set<Character> = ["─", "═", "━", "-", "_"]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var lastRuleIdx: Int? = nil
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && trimmed.allSatisfy({ ruleChars.contains($0) }) {
                lastRuleIdx = i
            }
        }
        guard let idx = lastRuleIdx, idx + 1 < lines.count else { return text }
        return lines[(idx + 1)...].joined(separator: "\n")
    }
}

// MARK: - Compiled gate (recursive boolean matcher)

/// A MatchGate with regexes compiled. `matches` returns true iff all substring
/// and regex matchers pass, all `all` gates pass, some `any` gate passes (when
/// non-empty), and no `not` gate matches — same semantics as herdr.
final class CompiledGate {
    private let contains: [String]
    private let regex: [NSRegularExpression]
    private let lineRegex: [NSRegularExpression]
    private let all: [CompiledGate]
    private let any: [CompiledGate]
    private let not: [CompiledGate]

    init(_ gate: MatchGate) {
        contains = gate.contains.map { $0.lowercased() }
        regex = gate.regex.compactMap { try? NSRegularExpression(pattern: $0) }
        lineRegex = gate.lineRegex.compactMap { try? NSRegularExpression(pattern: $0) }
        all = gate.all.map(CompiledGate.init)
        any = gate.any.map(CompiledGate.init)
        not = gate.not.map(CompiledGate.init)
    }

    func matches(_ text: String) -> Bool {
        for c in contains where !text.contains(c) { return false }
        for r in regex where !Self.matchesWhole(r, text) { return false }
        for r in lineRegex where !Self.matchesAnyLine(r, text) { return false }
        for g in all where !g.matches(text) { return false }
        if !any.isEmpty && !any.contains(where: { $0.matches(text) }) { return false }
        for g in not where g.matches(text) { return false }
        return true
    }

    private static func matchesWhole(_ r: NSRegularExpression, _ text: String) -> Bool {
        let ns = text as NSString
        return r.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func matchesAnyLine(_ r: NSRegularExpression, _ text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            let ns = s as NSString
            if r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil {
                return true
            }
        }
        return false
    }
}
