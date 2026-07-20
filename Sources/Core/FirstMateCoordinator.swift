import Foundation

/// Receives status-transition edges, runs the First Mate engine, and routes
/// green-zone actions to side-effect closures and red-zone actions to the queue.
/// Must be used on the main thread.
final class FirstMateCoordinator {
    private let config: FirstMateConfig
    private let queue: PendingOrdersQueue
    private let notify: (FirstMateAction) -> Void
    private let runInspection: (FirstMateAction) -> Void

    init(config: FirstMateConfig,
         queue: PendingOrdersQueue,
         notify: @escaping (FirstMateAction) -> Void,
         runInspection: @escaping (FirstMateAction) -> Void) {
        self.config = config
        self.queue = queue
        self.notify = notify
        self.runInspection = runInspection
    }

    func handle(_ outcome: IngestOutcome) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch outcome.event.kind {
        case .userPrompt:
            queue.resolveSuggest(terminalID: outcome.info.id)
        case .toolUse, .agentStopped:
            // The agent moved past its AskUserQuestion (answered in the TUI):
            // the question card is stale, clear it. (AskUserQuestion's own
            // tool_use_start is decoded as .question, so it can't self-clear.)
            queue.resolveQuestion(terminalID: outcome.info.id)
        case .screenObserved where outcome.newStatus != .waiting:
            // A viewport-discovered permission dialog disappeared. Remove its
            // card once the same pane is visibly no longer awaiting input.
            queue.resolveQuestion(terminalID: outcome.info.id)
        default:
            break
        }
        route(FirstMate.evaluate(outcome, config: config))
    }

    func handle(_ t: StatusTransition) {
        dispatchPrecondition(condition: .onQueue(.main))
        route(FirstMate.evaluate(t, config: config))
    }

    /// Pure routing of decided actions to side-effect closures / the queue.
    /// All adjudication lives in FirstMate.evaluate; this only dispatches.
    private func route(_ actions: [FirstMateAction]) {
        for action in actions {
            switch action.zone {
            case .green:
                switch action.kind {
                case .watchWaiting, .watchError:
                    notify(action)
                case .inspect, .autoCommit:
                    runInspection(action)
                case .suggestNextOrder, .returnToPort, .broadcastOrder:
                    break
                }
            case .red:
                switch action.kind {
                case .suggestNextOrder:
                    // Agent-supplied suggestion: replace any prior one from this pane.
                    NSLog("[suggest] pass gate3 → queue.upsert — worktree=\(action.worktreePath) options=\(action.options?.count ?? 0)")
                    queue.upsert(action)
                default:
                    queue.enqueue(action)
                }
            }
        }
    }
}
