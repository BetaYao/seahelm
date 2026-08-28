import Foundation

/// The one-line state of each integration checkout, keyed by its path.
///
/// Persisted so the card still reads correctly after a relaunch, before any
/// round has run. It is display text only — nothing decides anything from it.
final class IntegrationStatusStore {
    static let shared = IntegrationStatusStore()

    private let store = PersistedStringMap(fileName: "integration-status.json")

    private init() {}

    func status(forWorktree path: String) -> String? {
        store[WorktreeDiscovery.canonicalPath(path)]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    func set(_ status: String, forWorktree path: String) {
        store.set(status, forKey: WorktreeDiscovery.canonicalPath(path))
    }

    func forget(worktreePath path: String) {
        store.remove(forKey: WorktreeDiscovery.canonicalPath(path))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
