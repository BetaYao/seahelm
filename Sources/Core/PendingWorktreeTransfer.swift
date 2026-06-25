import Foundation

/// Records a pending worktree transfer intent from a WorktreeCreate hook event.
struct PendingWorktreeTransfer {
    let sourceWorktreePath: String
    let worktreeName: String
    let sessionId: String
    let recordedAt: Date
}

/// Tracks pending transfers between WorktreeCreate and the subsequent CwdChanged/discovery.
/// Thread-safe — guarded by NSLock.
class PendingTransferTracker {
    private var pending: [PendingWorktreeTransfer] = []
    private let lock = NSLock()
    /// Transfers older than this are discarded (seconds).
    private let ttl: TimeInterval = 30

    /// Record that a worktree creation is in progress.
    func record(sourceWorktreePath: String, worktreeName: String, sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        pruneStale()
        pending.append(PendingWorktreeTransfer(
            sourceWorktreePath: sourceWorktreePath,
            worktreeName: worktreeName,
            sessionId: sessionId,
            recordedAt: Date()
        ))
    }

    /// Try to match a newly discovered worktree path to a pending transfer.
    /// Matching strategy: the new path's last component equals the recorded worktreeName.
    /// Consumes (removes) the match if found.
    func consume(newWorktreePath: String) -> PendingWorktreeTransfer? {
        lock.lock()
        defer { lock.unlock() }
        pruneStale()
        let newName = URL(fileURLWithPath: newWorktreePath).lastPathComponent
        guard let index = pending.firstIndex(where: { $0.worktreeName == newName }) else {
            return nil
        }
        return pending.remove(at: index)
    }

    /// For testing: expire all entries immediately.
    func expireAll() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
    }

    private func pruneStale() {
        let cutoff = Date().addingTimeInterval(-ttl)
        pending.removeAll { $0.recordedAt < cutoff }
    }
}
