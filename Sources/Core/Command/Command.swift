import Foundation

/// What `/status` lists: the three tiers of the fleet.
enum StatusScope: String, Equatable {
    case panes
    case worktrees
    case repos
}

/// What `/go` points a conversation at.
enum GoTarget: Equatable {
    case pane(PaneRef)
    case worktree(WorktreeRef)
}

/// The command language, spoken identically by the desktop Helm line, the
/// chat bridge and mail. See `docs/command-redesign.md`.
///
/// Two sigils, each for one kind of thing:
///   - `#7` is a **pane**, by its stable handle.
///   - `@branch` / `@repo/branch` is a **worktree**; `@repo` is a **repo**.
///     Which of the two a verb takes is the verb's business, so a name never
///     needs a tie-break rule.
enum Command: Equatable {
    /// Anything without a leading slash: said to the pane this conversation is
    /// bound to.
    case say(String)
    /// `/new [@repo] <task>` — start a worktree, staff it, and bind to it.
    case new(task: String, repo: RepoRef?)
    /// `/go #pane` / `/go @worktree` — bind this conversation. On the desktop,
    /// select it.
    case go(GoTarget)
    /// `/show [#pane]` — the pane's recent output. Read-only; nil means the
    /// bound pane.
    case show(PaneRef?)
    /// `/order #pane <text>` — one message to one pane, binding untouched.
    case order(PaneRef, String)
    /// `/broadcast <text>` — to every pane. Confirms.
    case broadcast(String)
    /// `/status [worktrees|repos]` — a listing with handles.
    case status(StatusScope)
    /// `/return` — review every finished worktree.
    case returnAll
    /// `/return @worktree` — delete one linked worktree. Confirms.
    case returnWorktree(WorktreeRef)
    /// `/forget @repo` — stop tracking a repo; its worktrees stay on disk. Confirms.
    case forget(RepoRef)
    /// `/integrate [full]` — one integration round for the current repo.
    case integrate(mode: IntegrationConflictMode)
    /// `/idea <text>`
    case idea(String)
    /// `/feedback <text>` — open a GitHub issue for seahelm.
    case feedback(String)
    /// `/help [command]`
    case help(String?)
    /// `/yes` — confirm this conversation's pending action.
    case yes
    /// `/add` — desktop only; opens the repo picker.
    case add
}

/// One parsed line: the command plus the `force` tail that skips confirmation.
struct ParsedLine: Equatable {
    let command: Command
    let force: Bool

    init(_ command: Command, force: Bool = false) {
        self.command = command
        self.force = force
    }
}

enum CommandError: Error, Equatable {
    case empty
    case unknownCommand(String)
    /// A `#` argument that isn't a number.
    case badPaneRef(String)
    case unknownPane(Int)
    case unknownWorktree(String)
    /// The branch exists in several repos; the payload lists `repo/branch` forms.
    case ambiguousWorktree(String, [String])
    /// A repo name was given where a worktree was expected.
    case repoNotWorktree(String)
    case unknownRepo(String)
    /// A worktree name was given where a repo was expected.
    case worktreeNotRepo(String)
    case missingArgument(verb: String, what: String)
    case badArgument(verb: String, token: String)
    case cannotReturnMain(String)
}
