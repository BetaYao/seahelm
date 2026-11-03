import Foundation

/// What a control-socket call from First Mate is allowed to be. seahelm, not
/// the model, enforces this: the router asks before dispatching anything First
/// Mate sends.
enum AutopilotPolicy {
    enum Class: Equatable {
        /// Reads and waits: always allowed.
        case open
        /// An action under the autonomy policy.
        case gated(AutopilotAction)
        /// Not First Mate's to do at all (closing panes, rearranging layouts…).
        case forbidden
    }

    static let openMethods: Set<String> = [
        // A card, not an action: nothing runs until the user picks an option.
        "autopilot.propose",
        "ping", "session.snapshot", "pane.list", "pane.read", "fleet.groups", "layout.live",
        "message.snapshot", "message.history", "pane.explain", "agent.explain", "pane.options",
        "pane.wait_for_output", "wait.output", "pane.wait_agent_status", "wait.agent_status",
        "integration.status", "worktree.options",
    ]

    static func classify(method: String) -> Class {
        if openMethods.contains(method) { return .open }
        switch method {
        case "pane.run", "pane.send_text", "pane.send_keys": return .gated(.messagePane)
        case "worktree.create": return .gated(.startAgent)
        case "worktree.delete": return .gated(.deleteWorktree)
        default: return .forbidden
        }
    }

    /// Where the router puts a worktree's measured facts for the card to show.
    static let factsKey = "_facts"

    /// Measured facts for the worktree a deleting call names — what a card that
    /// would remove it has to show. Blocking (git): the router calls it on its
    /// own thread, before the policy hops to main.
    static func facts(forDeleting params: [String: Any]) -> String? {
        guard let path = params["worktree_path"] as? String, !path.isEmpty else { return nil }
        var facts = WorktreeFacts.probe(worktreePath: path)
        facts.busyPanes = WorktreeFacts.busyPanes(worktreePath: path)
        return facts.summary
    }

    /// Whether a control call comes from First Mate (its CLI exports its own
    /// session name as `SEAHELM_PANE_ID`, which arrives as `_meta.caller`).
    static func isFirstMate(caller: String?) -> Bool { caller == FirstMatePane.sessionName }

    /// One line for an approval card or the audit log.
    static func describe(method: String, params: [String: Any]) -> String {
        switch method {
        case "worktree.create":
            let repo = URL(fileURLWithPath: params["repo_path"] as? String ?? "").lastPathComponent
            let task = (params["prompt"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            return "Start an agent in \(repo): \(task.prefix(160))"
        case "worktree.delete":
            let wt = URL(fileURLWithPath: params["worktree_path"] as? String ?? "").lastPathComponent
            let facts = (params[factsKey] as? String).map { " — \($0)" } ?? ""
            return "Delete worktree \(wt)\(facts)"
        default:
            let pane = params["pane_id"] as? String ?? "?"
            let text = (params["command"] as? String) ?? (params["text"] as? String)
                ?? (params["keys"] as? [String])?.joined(separator: " ") ?? ""
            return "Tell \(pane): \(text.replacingOccurrences(of: "\n", with: " ").prefix(160))"
        }
    }
}

/// The policy's answer for one gated call.
enum AutopilotGate: Equatable {
    case allow
    /// Turned into an approval card with this id; nothing ran.
    case queued(String)
    case deny(String)
}

extension Notification.Name {
    /// First Mate's remote state changed; `userInfo` is the state (`firstMateState`).
    static let firstMateStateChanged = Notification.Name("seahelm.firstMateStateChanged")
}
