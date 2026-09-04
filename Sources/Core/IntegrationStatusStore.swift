import Foundation

/// What the last integration round produced for one checkout.
///
/// The card and the banner want one line; the Changes panel wants to say what
/// actually went in and what did not. Both come from here so they can never
/// disagree about the same round.
struct IntegrationPanelState: Codable, Equatable {
    /// The ambient one-liner for the card and the banner.
    var line: String
    /// Labels that merged, in the order applied.
    var included: [String]
    /// Labels dropped, each with the paths it collided on.
    var excluded: [Excluded]
    /// Paths carrying conflict markers, when the round kept conflicting sources.
    var conflictedPaths: [String]
    /// The result was built but not checked out — something in the checkout
    /// would have been destroyed by the reset.
    var isHeld: Bool
    /// What was in the way. Optional so state written before this existed still
    /// decodes — a card that falls back to the raw JSON reads far worse than a
    /// card missing one line.
    var heldPaths: [String]?
    /// Set instead of `heldPaths` when the hold was a commit made in the
    /// checkout rather than an uncommitted edit.
    var heldHead: String?

    struct Excluded: Codable, Equatable {
        var label: String
        var paths: [String]
    }

    init(line: String, included: [String], excluded: [Excluded], conflictedPaths: [String],
         isHeld: Bool, heldPaths: [String]? = nil, heldHead: String? = nil) {
        self.line = line
        self.included = included
        self.excluded = excluded
        self.conflictedPaths = conflictedPaths
        self.isHeld = isHeld
        self.heldPaths = heldPaths
        self.heldHead = heldHead
    }
}

/// Per-checkout state, keyed by worktree path.
///
/// Persisted so the card still reads correctly after a relaunch, before any
/// round has run. Display only — nothing decides anything from it.
final class IntegrationStatusStore {
    static let shared = IntegrationStatusStore()

    private let store = PersistedStringMap(fileName: "integration-status.json")

    private init() {}

    /// The one-liner. Falls back to the raw value for entries written before
    /// this held structured state, so an upgrade does not blank the card.
    func status(forWorktree path: String) -> String? {
        guard let raw = store[WorktreeDiscovery.canonicalPath(path)] else { return nil }
        if let state = Self.decode(raw) { return state.line.nilIfBlank }
        return raw.nilIfBlank
    }

    func state(forWorktree path: String) -> IntegrationPanelState? {
        store[WorktreeDiscovery.canonicalPath(path)].flatMap(Self.decode)
    }

    func set(_ state: IntegrationPanelState, forWorktree path: String) {
        guard let data = try? JSONEncoder().encode(state),
              let encoded = String(data: data, encoding: .utf8) else { return }
        store.set(encoded, forKey: WorktreeDiscovery.canonicalPath(path))
    }

    func forget(worktreePath path: String) {
        store.remove(forKey: WorktreeDiscovery.canonicalPath(path))
    }

    static func decode(_ raw: String) -> IntegrationPanelState? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(IntegrationPanelState.self, from: data)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
