import Foundation

/// Persists a session's label colour, keyed by worktree path, as JSON alongside
/// config.json (`~/.config/seahelm/worktree-labels.json`).
///
/// Its own file rather than a `Config` field on purpose: `Config` is a value
/// type three objects hold copies of, so a new map there has to be hand-synced
/// in `saveConfig` or another component's save silently drops it.
final class WorktreeLabelStore {
    static let shared = WorktreeLabelStore()

    private let store = PersistedStringMap(fileName: "worktree-labels.json")

    private init() {}

    /// The label recorded for this worktree path. An id this version doesn't
    /// know (written by a later one) reads as unlabelled rather than crashing.
    func label(forWorktree path: String) -> SessionLabel? {
        store[path].flatMap(SessionLabel.init(rawValue:))
    }

    /// Record the label, or clear it with nil. Persisted immediately, and
    /// announced with `.worktreeLabelDidChange` so surfaces that are not the
    /// fleet list (the island) repaint without waiting for their next refresh.
    func set(_ label: SessionLabel?, forWorktree path: String) {
        if let label {
            store.set(label.rawValue, forKey: path)
        } else {
            forget(worktreePath: path)
        }
        NotificationCenter.default.post(name: .worktreeLabelDidChange, object: nil)
    }

    /// Forget a deleted worktree, so a later worktree at the same path does not
    /// come up already wearing its colour.
    func forget(worktreePath path: String) {
        store.remove(forKey: path)
    }
}

extension Notification.Name {
    /// Posted on the caller's thread by `WorktreeLabelStore.set` — the row menu,
    /// so main.
    static let worktreeLabelDidChange = Notification.Name("seahelm.worktreeLabelDidChange")
}
