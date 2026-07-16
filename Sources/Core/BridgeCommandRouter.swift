import Foundation

struct BridgeCommandRouter {
    let queue: PendingOrdersQueue
    let createWorktree: (String, String?) -> Void
    let orderExisting: (String, String) -> Void
    let commit: (String) -> Void
    /// Scan all non-main worktrees and enqueue return-to-port cards for each.
    let removeAll: () -> Void
    /// Prompt (open panel) to add a repo to the workspace.
    let addRepo: () -> Void
    /// Confirm, then stop tracking the repo at this path (kills its sessions).
    let removeRepo: (String) -> Void
    /// Confirm, then delete the linked worktree at this path.
    let removeWorktree: (String) -> Void
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
        case .removeAll:
            removeAll()
        case .addRepo:
            addRepo()
        case .removeRepo(let path):
            removeRepo(path)
        case .removeWorktree(let path):
            removeWorktree(path)
        case .broadcast(let task):
            queue.enqueue(FirstMateAction(kind: .broadcastOrder, zone: .red, worktreePath: "",
                                          branch: "", project: "", terminalID: "",
                                          message: "Broadcast to \(activeSailorCount()) agents", payload: task))
        }
    }
}
