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

    /// Whether a pane is forked into `destination` without being asked: its
    /// agent created that worktree itself (the caller only asks then) and is
    /// working in it, it is not the pane's own worktree, and this pane has not
    /// been forked there already. A `cd` into a worktree someone else made is a
    /// visit and forks nothing.
    static func shouldAutoFork(enabled: Bool, filedWorktree: String, destination: String,
                               alreadyForked: Bool) -> Bool {
        enabled && !alreadyForked
            && PaneAwayIndicator.canonicalize(filedWorktree) != PaneAwayIndicator.canonicalize(destination)
    }

    /// What a fork that carries on (automatic, or `--continue`) is told. Its
    /// transcript ends on the call that forked it, so it is told not to fork
    /// or move again.
    static func continuePrompt(destination: String) -> String {
        "You have been forked into a new pane whose working directory is \(destination), "
            + "the worktree you were working in. Continue the task from where you left off, here. "
            + "The fork is done: do not run `seahelm pane fork` or `seahelm pane move` again."
    }

    /// The fork's own session name (claude `--name`): the destination's branch,
    /// else its directory. A fork copies the whole transcript, title included,
    /// so without one the new pane read exactly like the pane it came from.
    /// Claude records the name as the session's `custom-title`, which outranks
    /// the inherited title in `SessionTitleLookup`, its own terminal title and
    /// the resume picker. Capped, since the launch line is typed into a tty.
    static func sessionName(branch: String, worktreePath: String) -> String {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? URL(fileURLWithPath: worktreePath).lastPathComponent : trimmed
        return String(name.prefix(80))
    }

    /// Spool a fork's first message to a file the launch command reads and
    /// removes (see `AgentSessionRef.forkCommandLine`). Nil when it cannot be
    /// written; the fork then just waits at its prompt.
    static func writePromptFile(_ prompt: String,
                                directory: URL = FileManager.default.temporaryDirectory
                                    .appendingPathComponent("seahelm-fork-prompts")) -> String? {
        let file = directory.appendingPathComponent(UUID().uuidString + ".txt")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try prompt.write(to: file, atomically: true, encoding: .utf8)
            return file.path
        } catch {
            NSLog("[PaneFork] Could not write the fork prompt: \(error)")
            return nil
        }
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
