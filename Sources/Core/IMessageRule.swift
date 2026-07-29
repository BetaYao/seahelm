import Foundation

/// One "a message arrived → put an agent on it" rule.
///
/// This is the *signal* half of the iMessage bridge, and it is deliberately not
/// the command half. A command (`sea status`) is you talking to seahelm and gets
/// an answer; a signal is a third party — an Aliyun alert, a CI text, a person —
/// that you want to turn into work without answering it. So rules never reply,
/// and they never create anything: they route text into a pane that already
/// exists.
struct IMessageRule: Codable, Equatable {
    var name: String
    var enabled: Bool?
    /// Regex over the sender handle. Empty matches any sender.
    var from: String?
    /// Regex over the message body. Empty matches any body. Capture groups here
    /// are what `{{1}}`… in the prompt interpolate.
    var match: String?
    /// The prompt injected into the target pane. Supports `{{text}}` (whole
    /// message), `{{from}}` (sender), and `{{1}}`…`{{9}}` (capture groups).
    var prompt: String
    var target: IMessageRuleTarget

    var isEnabled: Bool { enabled ?? true }

    init(name: String = "",
         enabled: Bool? = nil,
         from: String? = nil,
         match: String? = nil,
         prompt: String = "",
         target: IMessageRuleTarget = IMessageRuleTarget(kind: .worktree, value: "")) {
        self.name = name
        self.enabled = enabled
        self.from = from
        self.match = match
        self.prompt = prompt
        self.target = target
    }
}

/// Where a rule sends its prompt. All three resolve to a pane that already
/// exists — a rule may not spawn one.
///
/// The reason is blast radius: an alerting source can fire hundreds of times in
/// a bad hour, and "create a worktree per alert" turns a noisy monitor into a
/// disk-filling fork bomb. Routing into an existing pane makes the worst case a
/// noisy pane.
struct IMessageRuleTarget: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        /// A specific pane, by `SEAHELM_PANE_ID` (session key) or instance id.
        case pane
        /// Any pane in this worktree path.
        case worktree
        /// Any pane in this project (repo name or path).
        case project
    }

    var kind: Kind
    var value: String
}

/// Matching and prompt rendering. Pure — the app layer owns pane lookup and
/// injection.
enum IMessageRuleEngine {
    struct Match: Equatable {
        let rule: IMessageRule
        /// The prompt with placeholders filled in.
        let prompt: String
    }

    /// First enabled rule whose sender *and* body patterns both match.
    ///
    /// First-wins rather than all-match: two rules firing on one alert would put
    /// the same text into two panes, which reads as a bug every time. Order the
    /// list from most specific to least.
    static func firstMatch(rules: [IMessageRule], sender: String, text: String) -> Match? {
        for rule in rules where rule.isEnabled {
            guard matches(pattern: rule.from, in: sender) != nil,
                  let groups = matches(pattern: rule.match, in: text) else { continue }
            return Match(rule: rule, prompt: render(rule.prompt, text: text,
                                                    from: sender, groups: groups))
        }
        return nil
    }

    /// Capture groups if `pattern` matches, `[]` if the pattern is empty (match
    /// anything), nil if it doesn't match or doesn't compile.
    ///
    /// An uncompilable pattern fails closed. A typo'd regex that matched
    /// everything would fire an agent on every text the user receives.
    ///
    /// `.` spans newlines. Alert texts are multi-line as often as not, and the
    /// natural way to write these patterns — `^(?=.*阿里云)(?=.*告警).*` — reads
    /// as "mentions both somewhere". Without dotall the lookaheads can only see
    /// the first line, so the same rule that worked all week fails silently the
    /// day the sender reflows their template.
    static func matches(pattern: String?, in subject: String) -> [String]? {
        guard let pattern = pattern?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pattern.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return nil }

        let range = NSRange(subject.startIndex..., in: subject)
        guard let match = regex.firstMatch(in: subject, options: [], range: range) else { return nil }

        var groups: [String] = []
        // Group 0 is the whole match; `{{1}}` is the first real capture.
        for index in 1..<match.numberOfRanges {
            guard let groupRange = Range(match.range(at: index), in: subject) else {
                groups.append("")
                continue
            }
            groups.append(String(subject[groupRange]))
        }
        return groups
    }

    static func render(_ template: String, text: String, from: String, groups: [String]) -> String {
        var out = template
            .replacingOccurrences(of: "{{text}}", with: text)
            .replacingOccurrences(of: "{{from}}", with: from)
        for (index, group) in groups.enumerated() {
            out = out.replacingOccurrences(of: "{{\(index + 1)}}", with: group)
        }
        // Unfilled group placeholders would otherwise reach the agent as literal
        // braces; an absent capture is empty, not `{{3}}`.
        return out.replacingOccurrences(of: "\\{\\{[1-9]\\}\\}", with: "",
                                        options: .regularExpression)
    }

    /// The pane a target names, or nil when nothing matches — a rule pointing at
    /// a worktree that has since been deleted does nothing rather than guessing
    /// at a neighbour.
    static func resolvePane(_ target: IMessageRuleTarget,
                            panes: [PaneSnapshot]) -> PaneSnapshot? {
        let needle = target.value.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }

        switch target.kind {
        case .pane:
            return panes.first { $0.paneSessionKey == needle || $0.paneId == needle }
        case .worktree:
            return panes.first { $0.worktreePath == needle }
                ?? panes.first { ($0.worktreePath as NSString).lastPathComponent == needle }
        case .project:
            return panes.first { $0.project == needle }
                ?? panes.first { ($0.project as NSString).lastPathComponent == needle }
        }
    }
}
