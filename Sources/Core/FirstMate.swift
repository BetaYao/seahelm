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
    let kind: FirstMateActionKind
    let zone: FirstMateZone
    let worktreePath: String
    let branch: String
    let project: String
    let terminalID: String
    let message: String
    let payload: String?
    let options: [String]?

    init(kind: FirstMateActionKind, zone: FirstMateZone, worktreePath: String,
         branch: String, project: String, terminalID: String, message: String,
         payload: String? = nil, options: [String]? = nil) {
        self.kind = kind
        self.zone = zone
        self.worktreePath = worktreePath
        self.branch = branch
        self.project = project
        self.terminalID = terminalID
        self.message = message
        self.payload = payload
        self.options = options
    }
}

struct StatusTransition {
    let worktreePath: String
    let branch: String
    let project: String
    let terminalID: String
    let oldStatus: SailorStatus
    let newStatus: SailorStatus
    let holdSeconds: Double
    let isCompletionSignal: Bool
}

/// Pure rule engine: status-transition edge + config → action list. No IO, no singletons.
enum FirstMate {
    /// Unified entry: folds the agent-suggestion path into the same pure rule engine.
    /// `.suggest` events become a red-zone suggestNextOrder carrying options; everything
    /// else derives a StatusTransition and runs the standard rules.
    static func evaluate(_ outcome: IngestOutcome, config: FirstMateConfig) -> [FirstMateAction] {
        guard config.enabled else { return [] }

        if case .suggest(let options) = outcome.event.kind {
            guard !options.isEmpty else { return [] }
            let i = outcome.info
            // Short summary of the agent's final message above the option buttons so the user
            // has context to choose. Sourced from the Stop hook's last_assistant_message
            // (stashed into lastMessage by the blocking Stop); the card truncates to 2 lines.
            let summary = String(i.lastMessage.prefix(200))
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
        } else if t.newStatus == .idle && config.autoSuggestNextOrder {
            actions.append(make(.suggestNextOrder, .red, "\(t.branch) idle, suggest next?"))
        }

        return actions
    }
}
