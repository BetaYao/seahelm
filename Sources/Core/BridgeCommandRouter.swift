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
    /// Confirm, then stop tracking the repo at this path (kills its sessions).
    let removeRepo: (String) -> Void
    /// Delete the linked worktree at this path. No confirmation — typing the
    /// command is the confirmation; git refuses if the tree is dirty.
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
        case .returnToPort(let path):
            returnWorktree(path)
        case .returnAll:
            returnAll()
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
