import Foundation

struct BridgeCommandRouter {
    let queue: PendingOrdersQueue
    let createWorktree: (String, String?) -> Void
    /// Make an existing worktree current.
    let selectWorktree: (String) -> Void
    /// Make one of the current worktree's agents current.
    let selectAgent: (String) -> Void
    /// Show the fleet. The desktop's listing is the dashboard, so this is a
    /// navigation, not text.
    let showOverview: () -> Void
    let orderAgent: (String, String) -> Void
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
        case .listWorktrees, .listAgents, .listRepos:
            showOverview()
        case .selectWorktree(let path):
            selectWorktree(path)
        case .selectAgent(let id):
            selectAgent(id)
        case .orderAgent(let id, let task):
            orderAgent(id, task)
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
