import Foundation

enum FirstMateZone: Equatable { case green, red }

enum FirstMateActionKind: Equatable {
    case watchWaiting
    case watchError
    case inspect
    case autoCommit
    case suggestNextOrder
    case returnToPort
    case broadcastOrder
}

struct FirstMateAction: Equatable {
    /// Payload marking an AskUserQuestion card (answered by option NUMBER in the
    /// TUI). Such cards auto-resolve once the agent moves on (tool use / stop).
    static let askUserQuestionPayload = "ask-user-question"
    /// A choice prompt discovered from the live terminal viewport. These are
    /// answered with arrow keys because not every TUI supports number shortcuts.
    static let screenChoicePayload = "screen-choice"

    static func isQuestionPayload(_ payload: String?) -> Bool {
        payload == askUserQuestionPayload || payload == screenChoicePayload
    }

    let kind: FirstMateActionKind
    let zone: FirstMateZone
    let worktreePath: String
    let branch: String
    let project: String
    let terminalID: String
    let message: String
    let payload: String?
    let options: [String]?
    /// Remaining AskUserQuestion questions after this card's — answering the
    /// card advances to the next instead of dropping the flow.
    let followups: [QuestionSpec]?

    init(kind: FirstMateActionKind, zone: FirstMateZone, worktreePath: String,
         branch: String, project: String, terminalID: String, message: String,
         payload: String? = nil, options: [String]? = nil,
         followups: [QuestionSpec]? = nil) {
        self.kind = kind
        self.zone = zone
        self.worktreePath = worktreePath
        self.branch = branch
        self.project = project
        self.terminalID = terminalID
        self.message = message
        self.payload = payload
        self.options = options
        self.followups = followups
    }
}

struct StatusTransition {
    let worktreePath: String
    let branch: String
    let project: String
    let terminalID: String
    let oldStatus: AgentStatus
    let newStatus: AgentStatus
    let holdSeconds: Double
    let isCompletionSignal: Bool
}

/// Pure rule engine: status-transition edge + config → action list. No IO, no singletons.
enum FirstMate {
    private static let maxSuggestionSummaryCharacters = 700

    /// Unified entry: folds the agent-suggestion path into the same pure rule engine.
    /// `.suggest` events become a red-zone suggestNextOrder carrying options; everything
    /// else derives a StatusTransition and runs the standard rules.
    static func evaluate(_ outcome: IngestOutcome, config: FirstMateConfig) -> [FirstMateAction] {
        guard config.enabled else { return [] }

        if case .question(let prompt, let options, let followups) = outcome.event.kind {
            guard !options.isEmpty else { return [] }
            let i = outcome.info
            let payload: String
            if case .scan = outcome.event.source {
                payload = FirstMateAction.screenChoicePayload
            } else {
                payload = FirstMateAction.askUserQuestionPayload
            }
            // The question itself is the summary. The payload tells the tap
            // handler whether to answer a native tool by number or drive a
            // viewport-discovered choice with arrow keys.
            return [FirstMateAction(kind: .suggestNextOrder, zone: .red,
                                    worktreePath: i.worktreePath, branch: i.branch,
                                    project: i.project, terminalID: i.id,
                                    message: String(prompt.prefix(200)),
                                    payload: payload, options: options,
                                    followups: followups.isEmpty ? nil : followups)]
        }

        if case .suggest(let options) = outcome.event.kind {
            guard !options.isEmpty else { return [] }
            let i = outcome.info
            // Short summary of the agent's final message above the option buttons so the user
            // has context to choose. Prefer lastAssistantMessage (Stop hook's
            // last_assistant_message, never clobbered by screen scans) over lastMessage,
            // which a poll may have overwritten with the `seahelm-suggest …` command line —
            // or, for Cursor, the Shell tool chrome when the agent invoked seahelm-suggest
            // via Bash instead of the sentinel line.
            let summary = suggestionSummary(
                lastAssistant: i.lastAssistantMessage, lastMessage: i.lastMessage)
            return [FirstMateAction(kind: .suggestNextOrder, zone: .red,
                                    worktreePath: i.worktreePath, branch: i.branch,
                                    project: i.project, terminalID: i.id,
                                    message: summary, options: options)]
        }

        guard outcome.statusChanged || outcome.isCompletionSignal else { return [] }
        let t = StatusTransition(
            worktreePath: outcome.info.worktreePath, branch: outcome.info.branch,
            project: outcome.info.project, terminalID: outcome.info.id,
            oldStatus: outcome.oldStatus, newStatus: outcome.newStatus,
            holdSeconds: outcome.holdSeconds, isCompletionSignal: outcome.isCompletionSignal)
        return evaluate(t, config: config)
    }

    /// Card summary above suggestion chips. Real assistant prose wins; viewport
    /// tool chrome (`Shell`, `Bash`, a `seahelm-suggest …` line) is treated as empty
    /// so the island doesn't pretend that was the agent's answer.
    static func suggestionSummary(lastAssistant: String, lastMessage: String) -> String {
        let prose = suggestionSummaryText(from: lastAssistant)
        if !prose.isEmpty { return prose }
        return suggestionSummaryText(from: lastMessage)
    }

    /// Normalize text for the body above suggestion chips: remove the sentinel
    /// option line, drop tool chrome, and keep enough multi-line answer context
    /// for the card to be useful.
    static func suggestionSummaryText(from raw: String) -> String {
        let stripped = StopHookResponder.stripSentinel(from: raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty, !isJunkSuggestionSummary(stripped) else { return "" }
        return String(stripped.prefix(maxSuggestionSummaryCharacters))
    }

    /// True when `s` is tool/UI chrome rather than assistant prose.
    static func isJunkSuggestionSummary(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.localizedCaseInsensitiveContains("seahelm-suggest") { return true }
        let lower = trimmed.lowercased()
        if ["shell", "bash", "zsh", "tool", "command"].contains(lower) { return true }
        // Non-AI pane display names ("Shell", "Docker", …) show up when the
        // scanner latches onto a tool header in Cursor's TUI.
        if AgentType.allCases.contains(where: {
            !$0.isAIAgent && $0.displayName.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return true
        }
        return false
    }

    static func evaluate(_ t: StatusTransition, config: FirstMateConfig) -> [FirstMateAction] {
        guard config.enabled else { return [] }

        func make(_ kind: FirstMateActionKind, _ zone: FirstMateZone, _ msg: String) -> FirstMateAction {
            FirstMateAction(kind: kind, zone: zone, worktreePath: t.worktreePath,
                            branch: t.branch, project: t.project,
                            terminalID: t.terminalID, message: msg)
        }

        var actions: [FirstMateAction] = []

        if t.newStatus == .waiting && t.holdSeconds >= config.waitingTimeoutSec {
            actions.append(make(.watchWaiting, .green, "\(t.branch) waiting"))
        }

        if t.newStatus == .error || t.newStatus == .exited {
            actions.append(make(.watchError, .green, "\(t.branch) error(\(t.newStatus.rawValue))"))
        }

        if t.isCompletionSignal {
            if config.autoInspect {
                actions.append(make(.inspect, .green, "\(t.branch) completed, inspecting"))
            }
            if config.autoCommit {
                actions.append(make(.autoCommit, .green, "\(t.branch) auto-commit"))
            }
        }

        return actions
    }
}
