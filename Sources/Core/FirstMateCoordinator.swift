import Foundation

/// Receives status-transition edges, runs the First Mate engine, and routes
/// green-zone actions to side-effect closures and red-zone actions to the queue.
/// Must be used on the main thread.
final class FirstMateCoordinator {
    private let config: FirstMateConfig
    private let queue: PendingOrdersQueue
    private let notify: (FirstMateAction) -> Void
    private let runInspection: (FirstMateAction) -> Void
    private let hasOrders: (String) -> Bool

    init(config: FirstMateConfig,
         queue: PendingOrdersQueue,
         notify: @escaping (FirstMateAction) -> Void,
         runInspection: @escaping (FirstMateAction) -> Void,
         hasOrders: @escaping (String) -> Bool) {
        self.config = config
        self.queue = queue
        self.notify = notify
        self.runInspection = runInspection
        self.hasOrders = hasOrders
    }

    func handle(_ t: StatusTransition) {
        dispatchPrecondition(condition: .onQueue(.main))
        for action in FirstMate.evaluate(t, config: config) {
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
                    if hasOrders(action.worktreePath) { queue.enqueue(action) }
                default:
                    queue.enqueue(action)
                }
            }
        }
    }
}
