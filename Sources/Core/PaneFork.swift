import Foundation

/// Forking a pane: when an agent has gone off into another worktree, open a
/// copy of its conversation in a new pane *there* and stop the original turn,
/// so each worktree keeps a pane whose agent is working in it. The original
/// pane and session stay — paused, not closed — and can be picked up again.
///
/// The orchestration lives in `TabCoordinator.forkPane`; this holds the parts
/// that decide something, so they can be pinned down without a live app.
enum PaneFork {
    /// The worktree to fork into. An explicit choice wins; otherwise wherever
    /// the hooks last saw the pane's agent, when that is a tracked worktree
    /// other than the one the pane is filed under. Nil = nowhere to go.
    static func target(explicit: String?, filedWorktree: String, hookWorktree: String?) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        guard let hook = hookWorktree, !hook.isEmpty,
              PaneAwayIndicator.canonicalize(hook) != PaneAwayIndicator.canonicalize(filedWorktree) else {
            return nil
        }
        return hook
    }

    /// Wait between the Esc and reading the transcript, so the interrupted turn
    /// is on disk before the fork copies it.
    static let interruptSettleDelay: TimeInterval = 1.0
}

enum PaneForkError: Error, Equatable {
    case unknownPane
    /// No resumable session recorded for the pane — its agent never reported one.
    case noSession
    /// The pane's agent has no fork command (only Claude does today).
    case unsupportedAgent
    /// No worktree named, and the agent is not away from the pane's own.
    case noTarget
    case unknownWorktree(String)
    case sameWorktree
    /// A `local` pane has no persistent session to start the fork in.
    case noPersistentBackend
    case launchFailed

    var message: String {
        switch self {
        case .unknownPane: return "pane not found"
        case .noSession: return "no agent session recorded for this pane"
        case .unsupportedAgent: return "this pane's agent can't fork a session"
        case .noTarget: return "the agent hasn't moved to another worktree — name one"
        case .unknownWorktree(let path): return "not a worktree seahelm tracks: \(path)"
        case .sameWorktree: return "the pane is already in that worktree"
        case .noPersistentBackend: return "forking needs the zmx backend"
        case .launchFailed: return "the forked session didn't start"
        }
    }

    var code: Int {
        switch self {
        case .unknownPane, .unknownWorktree, .noSession: return ControlError.notFound
        default: return ControlError.invalidRequest
        }
    }
}
