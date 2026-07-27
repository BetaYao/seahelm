import Foundation

/// Owns the transient keyboard substate (a pending delete, an open create form).
///
/// This used to be `KeyboardModeController` and also carried a NORMAL/INSERT mode.
/// That mode was derived from `chromeState.isCollapsed` and kept in sync by hand, and
/// its only consumer hardcoded `.normal` — so it decided nothing while being able to
/// drift. What remains is the part with real semantics: a substate that temporarily
/// changes what bare keys mean.
final class KeyboardSubstateController {
    private(set) var substate: KeyboardSubstate = .none

    /// True while a substate is claiming bare keys, so callers can skip their own
    /// handling instead of racing it.
    var isIdle: Bool { substate == .none }

    // MARK: - Delete confirmation

    func beginDelete(agentId: String) {
        substate = .deletePending(agentId: agentId)
    }

    /// Returns the agent id to delete when a delete was pending, else nil.
    @discardableResult
    func confirmDelete() -> String? {
        guard case .deletePending(let agentId) = substate else { return nil }
        substate = .none
        return agentId
    }

    func cancelDelete() {
        guard case .deletePending = substate else { return }
        substate = .none
    }

    // MARK: - Inline create form

    func beginCreateForm() { substate = .createForm }

    func endCreateForm() {
        guard case .createForm = substate else { return }
        substate = .none
    }

    /// Drop any pending substate (e.g. focus left the dashboard entirely).
    func reset() { substate = .none }
}
