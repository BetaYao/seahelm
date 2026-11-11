import Foundation

/// One pane as the command language sees it.
struct PaneRef: Equatable {
    /// seahelm-core's stable `#n` (`CoreLink.handles`): what `#7` means on
    /// every surface. Nil until the core has listed the pane.
    let handle: Int?
    /// Station id, Fleet's key for the live pane.
    let id: String
    /// `SEAHELM_PANE_ID`. Empty for a local (non-seahelmd) pane.
    let sessionKey: String
    let project: String
    let branch: String
    let worktreePath: String
    /// Agent kind, e.g. "Claude".
    let type: String
    /// This pane's own title — distinct per pane, unlike the worktree's.
    let title: String
    let status: AgentStatus
    let lastMessage: String

    init(handle: Int?, id: String, sessionKey: String = "",
         project: String, branch: String, worktreePath: String,
         type: String, title: String, status: AgentStatus = .unknown, lastMessage: String = "") {
        self.handle = handle
        self.id = id
        self.sessionKey = sessionKey
        self.project = project
        self.branch = branch
        self.worktreePath = worktreePath
        self.type = type
        self.title = title
        self.status = status
        self.lastMessage = lastMessage
    }
}

struct WorktreeRef: Equatable {
    /// Repo display name (its directory name).
    let repo: String
    let branch: String
    let path: String
    let isMain: Bool

    init(repo: String, branch: String, path: String, isMain: Bool = false) {
        self.repo = repo
        self.branch = branch
        self.path = path
        self.isMain = isMain
    }

    /// What this worktree is called: its branch, or its directory when it has
    /// none.
    ///
    /// A worktree on a detached HEAD has no branch, and an integration checkout
    /// is deliberately one. Naming it by the empty string printed it as a blank
    /// group header in `/status` — which reads as a formatting bug rather than
    /// a worktree — and left it unaddressable, since `@name` matches on branch.
    var name: String { Self.name(branch: branch, path: path) }

    static func name(branch: String, path: String) -> String {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let directory = URL(fileURLWithPath: path).lastPathComponent
        return directory.isEmpty ? path : directory
    }
}

struct RepoRef: Equatable {
    /// Directory name — what `@repo` is matched against.
    let name: String
    let path: String
}

/// The fleet as the Helm line's autocomplete offers it (`#` panes, `@`
/// repos and worktrees), built from live state. The commands themselves are
/// seahelm-core's (`command.run`).
struct FleetIndex: Equatable {
    var panes: [PaneRef]
    var worktrees: [WorktreeRef]
    var repos: [RepoRef]

    static let empty = FleetIndex()

    init(panes: [PaneRef] = [], worktrees: [WorktreeRef] = [], repos: [RepoRef] = []) {
        self.panes = panes
        self.worktrees = worktrees
        self.repos = repos
    }

    // MARK: - Worktrees

    /// `@name`, or `@repo/name` when the bare one would be ambiguous.
    /// The listing prints this form, so what you read is what you can type.
    func label(for worktree: WorktreeRef) -> String {
        let sameName = worktrees.filter { $0.name.lowercased() == worktree.name.lowercased() }
        return sameName.count > 1 ? "@\(worktree.repo)/\(worktree.name)" : "@\(worktree.name)"
    }

    func worktree(path: String) -> WorktreeRef? {
        worktrees.first { $0.path == path }
    }

    /// Source printed for a card in the shared timeline: the pane's handle,
    /// its title (the user's name for it, else its own), and the worktree the
    /// card belongs to rather than the containing repo. Several panes share a
    /// worktree, so the title is what tells their cards apart.
    func cardSourceLabel(for pane: PaneRef) -> String {
        let worktreeName = worktree(path: pane.worktreePath)?.name
            ?? WorktreeRef.name(branch: pane.branch, path: pane.worktreePath)
        let name = worktreeName.isEmpty ? pane.project : worktreeName
        let title = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if let handle = pane.handle { parts.append("#\(handle)") }
        if !title.isEmpty, title.lowercased() != name.lowercased() { parts.append(title) }
        if !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " · ")
    }
}
