import Foundation

/// Records that a pane's agent has moved into a worktree seahelm does not track
/// yet, so the pane can follow it there once discovery integrates the worktree.
struct PendingWorktreeTransfer {
    /// Canonical path of the worktree the agent moved into.
    let worktreePath: String
    /// Stable pane id (zmx session name from SEAHELM_PANE_ID) of the pane whose
    /// agent moved. The transfer moves this pane alone, never its siblings.
    let paneId: String
    let recordedAt: Date
}

/// Bridges the gap between "an agent's cwd named an untracked worktree" and the
/// asynchronous discovery that integrates it. Thread-safe — guarded by NSLock.
///
/// Matching is by canonical path, not by directory name. Name matching paired a
/// new worktree with a same-named source in an unrelated repo, and the transfer
/// then destroyed that source's tree with no way back until relaunch; the cwd we
/// record here is already the exact path, so the ambiguity simply does not arise.
class PendingTransferTracker {
    private var pending: [PendingWorktreeTransfer] = []
    private let lock = NSLock()
    /// Transfers older than this are discarded (seconds).
    private let ttl: TimeInterval = 30

    /// Record that `paneId`'s agent is working in `worktreePath`, which is not
    /// integrated yet. Re-recording the same path refreshes it rather than
    /// stacking duplicates — the cwd check upstream is edge-triggered but retries.
    func record(worktreePath: String, paneId: String) {
        lock.lock()
        defer { lock.unlock() }
        pruneStale()
        pending.removeAll { $0.worktreePath == worktreePath }
        pending.append(PendingWorktreeTransfer(
            worktreePath: worktreePath,
            paneId: paneId,
            recordedAt: Date()
        ))
    }

    /// Try to match a newly discovered worktree to a pending transfer, consuming
    /// (removing) the match. Compares canonical paths, so callers may pass either
    /// form.
    func consume(newWorktreePath: String) -> PendingWorktreeTransfer? {
        lock.lock()
        defer { lock.unlock() }
        pruneStale()
        let canon = WorktreeDiscovery.canonicalPath(newWorktreePath)
        guard let index = pending.firstIndex(where: {
            WorktreeDiscovery.canonicalPath($0.worktreePath) == canon
        }) else {
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
