import Foundation

/// Persists the branch a worktree was created from, keyed by worktree path.
///
/// git does not record this: `git worktree add -b B <path> A` leaves no trace
/// that `A` was the base, and `-b` off a local branch sets no upstream either.
/// So a worktree stacked on another agent's branch is indistinguishable from
/// one cut off main — which is why the diff base used to be guessed from a
/// fixed list of trunk names, and why a stacked worktree showed the branch
/// below it as its own work.
///
/// seahelm does know: the user picked the base in the new-branch dialog. This
/// just remembers it. Stored as JSON alongside config.json
/// (`~/.config/seahelm/worktree-bases.json`).
final class WorktreeBaseBranchStore {
    static let shared = WorktreeBaseBranchStore()

    private let store = PersistedStringMap(fileName: "worktree-bases.json")

    private init() {}

    /// The branch this worktree was cut from, if seahelm created it.
    func baseBranch(forWorktree path: String) -> String? {
        guard let value = store[path]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// Record the base at creation time.
    func set(_ baseBranch: String, forWorktree path: String) {
        let trimmed = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.set(trimmed, forKey: path)
    }

    /// Forget a deleted worktree, so a later worktree at the same path does not
    /// inherit its base.
    func forget(worktreePath path: String) {
        store.remove(forKey: path)
    }
}
