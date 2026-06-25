import Foundation

struct BridgeCommandRouter {
    let queue: PendingOrdersQueue
    let createWorktree: (String) -> Void
    let orderExisting: (String, String) -> Void
    let commit: (String) -> Void
    let activeSailorCount: () -> Int
    let branchForPath: (String) -> String
    let projectForPath: (String) -> String

    func route(_ command: BridgeCommand) {
        switch command {
        case .newWorktree(let task):
            createWorktree(task)
        case .orderExisting(let path, let task):
            orderExisting(path, task)
        case .commit(let path):
            commit(path)
        case .returnToPort(let path):
            let branch = branchForPath(path)
            queue.enqueue(FirstMateAction(kind: .returnToPort, zone: .red, worktreePath: path,
                                          branch: branch, project: projectForPath(path),
                                          terminalID: "", message: "\(branch) 返港删除?"))
        case .broadcast(let task):
            queue.enqueue(FirstMateAction(kind: .broadcastOrder, zone: .red, worktreePath: "",
                                          branch: "", project: "", terminalID: "",
                                          message: "广播给 \(activeSailorCount()) 个 agent", payload: task))
        }
    }
}
