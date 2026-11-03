import Foundation

/// Where First Mate lives: one zmx session, one working directory, and the files
/// seahelm keeps there. See docs/first-mate-autopilot.md §2.2.
enum FirstMatePane {
    static let sessionName = "seahelm-first-mate"
    static let project = "First Mate"

    static var directory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/seahelm/first-mate").path
    }
    static var ledgerPath: String { directory + "/state.json" }
    static var auditPath: String { directory + "/audit.jsonl" }
    static var standingOrdersPath: String { directory + "/standing-orders.md" }
    /// The `version` the live session was launched under. A session outlives the
    /// app, so a fix to how First Mate is started only reaches it by replacing it.
    static var sessionVersionPath: String { directory + "/.session-version" }

    /// Version and agent: switching agent replaces the session as surely as a
    /// new version does.
    static func sessionStamp(agent: AgentType) -> String { "\(version):\(agent.rawValue)" }

    static func sessionIsCurrent(agent: AgentType = .claudeCode, at dir: String = directory) -> Bool {
        (try? String(contentsOfFile: dir + "/.session-version", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == sessionStamp(agent: agent)
    }

    static func markSessionCurrent(agent: AgentType = .claudeCode, at dir: String = directory) {
        try? sessionStamp(agent: agent).write(toFile: dir + "/.session-version", atomically: true, encoding: .utf8)
    }

    /// The agents First Mate can be. Each needs a way to be held to read-mostly
    /// work that does not depend on it behaving: Claude Code's permission rules,
    /// Codex's sandbox. Agents without one are not offered.
    static let agents: [AgentType] = [.claudeCode, .codex]

    /// What keeps it in bounds, for Settings to say.
    static func guardDescription(_ agent: AgentType) -> String {
        switch agent {
        case .codex:
            return "Codex runs in its workspace-write sandbox: it can write only its own folder and asks before anything else. Network is on so gh and seahelm work — which also means gh commands that only touch GitHub (gh pr merge) are held back by its instructions, not by the sandbox."
        default:
            return "Claude Code runs with a permission allowlist: reads, read-only gh/git and seahelm run unasked; git push, gh pr merge, git worktree remove and rm are refused; anything else asks you."
        }
    }

    /// Whether a pane is First Mate rather than a member of the fleet.
    static func isFirstMate(worktreePath: String) -> Bool { worktreePath == directory }

    /// Bumped whenever `instructions` or `permissions` change, so an existing
    /// directory picks the new ones up. The files are seahelm's, not the user's:
    /// what the user says to keep goes in `standing-orders.md`, never touched.
    static let version = 4

    /// Write the managed files (when stale) and the standing orders (when absent).
    static func provision(at dir: String = directory) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir + "/.claude", withIntermediateDirectories: true)
        let marker = "<!-- seahelm-first-mate v\(version) -->"
        // Both names: Claude Code reads CLAUDE.md, Codex reads AGENTS.md.
        for name in ["CLAUDE.md", "AGENTS.md"] {
            let path = dir + "/" + name
            if (try? String(contentsOfFile: path, encoding: .utf8))?.contains(marker) != true {
                try? (marker + "\n" + instructions).write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let settings = dir + "/.claude/settings.json"
        if let data = try? JSONSerialization.data(withJSONObject: permissions, options: [.prettyPrinted, .sortedKeys]),
           (try? Data(contentsOf: URL(fileURLWithPath: settings))) != data {
            try? data.write(to: URL(fileURLWithPath: settings), options: .atomic)
        }
        let orders = dir + "/standing-orders.md"
        if !fm.fileExists(atPath: orders) {
            try? "# Standing orders\n\nWhat the user has asked First Mate to keep doing (or not doing).\n"
                .write(toFile: orders, atomically: true, encoding: .utf8)
        }
    }

    /// Starts First Mate's agent. `--permission-mode default` because a user-level
    /// `defaultMode: bypassPermissions` (common among people who run many agents)
    /// would otherwise switch the gate below off; a CLI flag outranks every
    /// settings file.
    static let launchCommand = "claude --permission-mode default"

    /// Codex in its workspace-write sandbox (writes only here), asking before it
    /// steps out, with network on — without it neither `gh` nor the seahelm
    /// socket is reachable from inside the sandbox. Never the bypass flag.
    static let codexLaunchCommand =
        "codex --sandbox workspace-write --ask-for-approval on-request -c sandbox_workspace_write.network_access=true"

    static func launchCommand(for agent: AgentType) -> String {
        agent == .codex ? codexLaunchCommand : launchCommand
    }

    /// Claude Code's own permission gate for this directory. seahelm enforces the
    /// autonomy policy on its CLI, but an agent free to run any shell command
    /// could step around it (`git worktree remove`, `gh pr merge`). So only reads
    /// and `seahelm` itself run unasked; anything else stops at Claude's prompt,
    /// which shows as First Mate needing you.
    static let permissions: [String: Any] = [
        "permissions": [
            // Belt to the launch flag's braces: this project's settings outrank
            // the user's, so a bypass set there does not reach First Mate.
            "defaultMode": "default",
            "allow": [
                "Bash(seahelm:*)",
                "Bash(gh pr view:*)", "Bash(gh pr list:*)", "Bash(gh pr checks:*)", "Bash(gh pr diff:*)",
                "Bash(gh run view:*)", "Bash(gh run list:*)",
                "Bash(gh issue view:*)", "Bash(gh issue list:*)",
                "Bash(git -C:*)", "Bash(git status:*)", "Bash(git log:*)", "Bash(git diff:*)",
                "Read", "Grep", "Glob",
                "Edit(standing-orders.md)", "Write(standing-orders.md)",
            ],
            "deny": [
                "Bash(gh pr merge:*)", "Bash(git push:*)", "Bash(git worktree remove:*)", "Bash(rm:*)",
            ],
        ],
    ]

    static let instructions = """
    # You are First Mate

    You supervise a fleet of coding agents running in seahelm, a terminal multiplexer.
    The fleet is repos → worktrees → panes, each pane running an agent. You do not write
    code yourself; you notice, decide, and direct.

    ## How work reaches you

    - **Events** arrive as messages that start with `[seahelm event]`. The header names the
      trigger (`ci.failed`, `pr.merged`, …), the rule that matched, the repo, worktree,
      branch and PR, and the autonomy for each action. The rule's brief follows. Several
      events may arrive in one message, separated by `---`.
    - **The user** talks to you directly. Their words outrank any event.

    ## How you act

    Use the `seahelm` CLI (see the seahelm skill) and read-only `gh`/`git`:

    - `seahelm pane list` — every pane: id, worktree, agent, status.
    - `seahelm pane read <pane> --source recent --lines 200` — what a pane shows.
    - `seahelm pane run <pane> <text>` — tell an agent something (types it and presses Enter).
      Only when its status is `Idle`; never interrupt a `Running` agent.
    - `seahelm worktree create --repo <path> --task <text>` — a new worktree with an agent
      briefed on the task. Write the task as you would brief a colleague: what, why, where.
    - `seahelm worktree delete <worktree-path>` — remove a worktree that is done with.
    - `gh pr view <n>`, `gh pr checks <n>`, `gh run view <id> --log-failed` — find out why.
    - `seahelm propose --json '<doc>'` — offer the user a choice as a card (island, Telegram);
      picking an option runs that option's action, no second question. The document:
      `{"summary": "Three issues worth starting", "options": [{"label": "Start #88 login 500",
      "action": "worktree.create", "params": {"repo_path": "/path/to/repo", "prompt": "<brief>"}}]}`.
      Up to five options; each action is one you could run yourself (`worktree.create`,
      `worktree.delete`, `pane.run` with `pane_id` and `command`). You are told what was picked.

    Every action goes through seahelm's policy. An answer of `{"queued": "approval"}` means
    the user will decide; it is not an error. Say what you proposed and move on — seahelm
    sends you a `[seahelm] The user approved/rejected …` message with the outcome later.
    An action refused outright (`not available to First Mate`, `set to deny`, a budget) is
    final: report it, do not look for another way to do the same thing.

    ## Rules of conduct

    - Find out before you act: read the failure, read the pane, then decide.
    - Tell an agent *what* broke and *where to look*, not how to fix it line by line.
    - One event, one short report: what you saw, what you did, what is pending.
    - Keep `standing-orders.md` up to date when the user says "remember …" or "from now on …",
      and read it before acting on any event.
    - Never run destructive commands. If something needs one, say so and stop.
    """
}
