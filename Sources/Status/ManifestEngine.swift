import Foundation

// MARK: - Detection result

/// Rich detection output (mirrors herdr's AgentDetection). Carries the visible_*
/// flags used for publish gating / debounce bypass, plus the matched rule id for
/// explainability (`agent explain`).
struct Detection: Equatable {
    var state: SailorStatus
    var visibleIdle: Bool = false
    var visibleBlocker: Bool = false
    var visibleWorking: Bool = false
    var skipStateUpdate: Bool = false
    var matchedRuleId: String? = nil

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

    struct CompiledRule {
        let rule: ManifestRule
        let region: ManifestRegion
        let gate: CompiledGate
    }

    init(_ manifest: AgentManifest) {
        self.manifest = manifest
        self.compiledRules = manifest.rules
            .sorted { $0.priority > $1.priority }   // stable: ties keep source order
            .map { CompiledRule(rule: $0, region: ManifestRegion($0.region), gate: CompiledGate($0.gate)) }
    }

    /// Evaluate all rules; highest-priority match wins. Returns `.unknown`
    /// (falling through to default_status handling by the caller) if none match.
    func evaluate(_ input: DetectionInput) -> Detection {
        for cr in compiledRules {
            let text = Self.regionText(cr.region, input)
            guard cr.gate.matches(text) else { continue }
            return Detection(
                state: SailorStatus.fromManifest(cr.rule.state),
                visibleIdle: cr.rule.visibleIdle,
                visibleBlocker: cr.rule.visibleBlocker,
                visibleWorking: cr.rule.visibleWorking,
                skipStateUpdate: cr.rule.skipStateUpdate,
                matchedRuleId: cr.rule.id
            )
        }
        return Detection.unknown
    }

    /// Default fallback when no rule matched a known agent.
    var defaultStatus: SailorStatus { SailorStatus.fromManifest(manifest.defaultStatus) }

    /// Explainability: the winning rule plus the region text it matched against
    /// (evidence), or nil if no rule matched. Same evaluation order as `evaluate`.
    func matchDetail(_ input: DetectionInput) -> (rule: ManifestRule, regionText: String)? {
        for cr in compiledRules {
            let text = Self.regionText(cr.region, input)
            if cr.gate.matches(text) { return (cr.rule, text) }
        }
        return nil
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
        // OSC/prompt tracker lands (阶段 A5).
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
