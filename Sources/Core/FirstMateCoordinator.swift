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
        if case .userPrompt = outcome.event.kind {
            queue.resolveSuggest(worktreePath: outcome.info.worktreePath)
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
                    // Agent-supplied suggestion: replace any prior one for this worktree.
                    queue.upsert(action)
                default:
                    queue.enqueue(action)
                }
            }
        }
    }
}
