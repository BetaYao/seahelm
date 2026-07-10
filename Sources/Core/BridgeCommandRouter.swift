import Foundation

struct BridgeCommandRouter {
    let queue: PendingOrdersQueue
    let createWorktree: (String, String?) -> Void
    let orderExisting: (String, String) -> Void
    let commit: (String) -> Void
    /// Run merge check and enqueue a return-to-port confirmation card for one worktree.
    let returnWorktree: (String) -> Void
    /// Scan all non-main worktrees and enqueue return-to-port cards for each.
    let returnAll: () -> Void
    /// Prompt (open panel) to add a repo to the workspace.
    let addRepo: () -> Void
    let activeSailorCount: () -> Int
    let branchForPath: (String) -> String
    let projectForPath: (String) -> String

    func route(_ command: BridgeCommand) {
        switch command {
        case .newWorktree(let task, let repoHint):
            createWorktree(task, repoHint)
        case .orderExisting(let path, let task):
            orderExisting(path, task)
        case .commit(let path):
            commit(path)
        case .returnToPort(let path):
            returnWorktree(path)
        case .returnAll:
            returnAll()
        case .addRepo:
            addRepo()
        case .broadcast(let task):
            queue.enqueue(FirstMateAction(kind: .broadcastOrder, zone: .red, worktreePath: "",
                                          branch: "", project: "", terminalID: "",
                                          message: "Broadcast to \(activeSailorCount()) agents", payload: task))
        }
    }
}
