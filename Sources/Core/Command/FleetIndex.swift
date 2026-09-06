import Foundation

/// One pane as the command language sees it.
struct PaneRef: Equatable {
    /// The stable, per-install number: what `#7` means on every surface.
    let handle: Int
    /// The key the handle was minted for — see `PaneHandleRegistry.key`.
    let handleKey: String
    /// Station id, AgentRegistry's key for the live pane.
    let id: String
    /// `SEAHELM_PANE_ID`. Empty for a local (non-zmx) pane.
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

    init(handle: Int, handleKey: String, id: String, sessionKey: String = "",
         project: String, branch: String, worktreePath: String,
         type: String, title: String, status: AgentStatus = .unknown, lastMessage: String = "") {
        self.handle = handle
        self.handleKey = handleKey
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

/// The fleet frozen for one parse: everything a command can name.
///
/// Built by the app layer from live state and handed to the parser, so the
/// parser stays pure — no singletons, no IO — and a test can hand it any
/// fleet it likes.
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

    // MARK: - Panes

    func pane(handle: Int) -> PaneRef? {
        panes.first { $0.handle == handle }
    }

    func pane(handleKey: String) -> PaneRef? {
        panes.first { $0.handleKey == handleKey }
    }

    func pane(id: String) -> PaneRef? {
        panes.first { $0.id == id }
    }

    /// Panes in one worktree, lowest handle first — the oldest pane is the
    /// one a worktree-level binding falls back to.
    func panes(inWorktree path: String) -> [PaneRef] {
        panes.filter { $0.worktreePath == path }.sorted { $0.handle < $1.handle }
    }

    // MARK: - Worktrees

    /// `name`, or `repo/name` when several repos carry it. Case-insensitive, as
    /// these are typed from memory. Matching is on `WorktreeRef.name`, so a
    /// detached checkout answers to its directory.
    func worktree(named name: String) -> Result<WorktreeRef, CommandError> {
        let needle = name.lowercased()
        if let slash = needle.firstIndex(of: "/") {
            let repo = needle[..<slash]
            let branch = needle[needle.index(after: slash)...]
            if let hit = worktrees.first(where: {
                $0.repo.lowercased() == repo && $0.name.lowercased() == branch
            }) {
                return .success(hit)
            }
            return .failure(.unknownWorktree(name))
        }

        let hits = worktrees.filter { $0.name.lowercased() == needle }
        switch hits.count {
        case 0:
            // Naming a repo where a worktree is expected is the one mistake the
            // old `/return` grammar invited; say what the name actually is.
            return .failure(repo(named: name) != nil ? .repoNotWorktree(name) : .unknownWorktree(name))
        case 1:
            return .success(hits[0])
        default:
            return .failure(.ambiguousWorktree(name, hits.map { "\($0.repo)/\($0.name)" }))
        }
    }

    /// `@name`, or `@repo/name` when the bare one would be ambiguous.
    /// The listing prints this form, so what you read is what you can type.
    func label(for worktree: WorktreeRef) -> String {
        let sameName = worktrees.filter { $0.name.lowercased() == worktree.name.lowercased() }
        return sameName.count > 1 ? "@\(worktree.repo)/\(worktree.name)" : "@\(worktree.name)"
    }

    func worktree(path: String) -> WorktreeRef? {
        worktrees.first { $0.path == path }
    }

    // MARK: - Repos

    func repo(named name: String) -> RepoRef? {
        let needle = name.lowercased()
        return repos.first { $0.name.lowercased() == needle }
    }
}
