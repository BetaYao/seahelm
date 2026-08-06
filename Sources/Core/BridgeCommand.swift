import Foundation

struct CabinRef: Equatable {
    /// Repo display name. A branch alone is ambiguous once the workspace holds
    /// more than one repo — several can carry the same branch name, and the
    /// chat listing is the one surface with no tab bar to disambiguate it.
    let repo: String
    let branch: String
    let path: String
}

/// An agent as the command language sees it — one split pane running one agent.
struct AgentRef: Equatable {
    let id: String
    let project: String
    let branch: String
    /// Agent kind, e.g. "Claude".
    let type: String
    /// This agent's own session title. Distinct per agent, unlike the
    /// worktree-keyed title the dashboard shows.
    let title: String
    /// Carried so a listing can show state without a second lookup. Defaulted
    /// because the desktop paths that only select never read them.
    let status: SailorStatus
    let lastMessage: String

    init(id: String, project: String, branch: String, type: String, title: String,
         status: SailorStatus = .unknown, lastMessage: String = "") {
        self.id = id
        self.project = project
        self.branch = branch
        self.type = type
        self.title = title
        self.status = status
        self.lastMessage = lastMessage
    }
}

/// The command language, spoken identically by the desktop Helm line and the
/// chat channel.
///
/// Two sigils, and they are not interchangeable:
///   - `@name` picks a **repo** (`/worktree @seahelm …`) or, for `/return`, a repo
///     or a branch.
///   - `#code|name` picks an existing **worktree** (`/worktree #2`) or **pane**
///     (`/order #1 …`). It is what disambiguates selecting from creating:
///     `/worktree fix login` starts work, `/worktree #3` moves to it.
enum BridgeCommand: Equatable {
    /// `/worktree` — every worktree, numbered.
    case listWorktrees
    /// `/worktree [@repo] <description>` — start a worktree and make it current.
    case newWorktree(task: String, repoHint: String? = nil)
    /// `/worktree #<code|branch>` — make an existing worktree current.
    case selectWorktree(path: String)
    /// `/pane` — every pane in the current worktree, numbered.
    case listAgents
    /// `/pane #<code|name>` — make one of them current.
    case selectAgent(id: String)
    /// `/order #<code|name> <task>` — send to one pane without moving current.
    case orderAgent(agentId: String, task: String)
    case broadcast(task: String)
    case addRepo
    /// `/return` — scan every non-main worktree and clean up whatever is done.
    case removeAll
    /// `/return @repo` — stop tracking a repo: kills its sessions, leaves every
    /// worktree on disk.
    case removeRepo(repoPath: String)
    /// `/return @branch` — delete one linked worktree (never the main one — that
    /// is `removeRepo`).
    case removeWorktree(worktreePath: String)
    /// `/feedback <description>` — open a GitHub issue pre-filled with the description.
    case flagIssue(title: String)
}

enum BridgeCommandError: Error, Equatable {
    case emptyTask
    case unknownCommand(String)
    case unknownBranch(String)
    case unknownTarget(String)
    case missingArgument(String)
}

/// Pure parser: text + the lists it selects from → BridgeCommand. No IO, no singletons.
enum BridgeCommandParser {
    /// Extract a leading `@name` token from text, returning (repoPath, cleanedText).
    /// Matches against repo directory names (case-insensitive). Returns nil repoPath if no match.
    static func extractRepoHint(_ text: String, repoPaths: [String]) -> (repoPath: String?, task: String) {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = tokens.first, first.hasPrefix("@") else { return (nil, text) }
        let name = String(first.dropFirst()).lowercased()
        let matched = repoPaths.first {
            URL(fileURLWithPath: $0).lastPathComponent.lowercased() == name
        }
        let rest = tokens.dropFirst().joined(separator: " ")
        return (matched, rest.isEmpty ? text : rest)
    }

    /// Resolve what `/return @x` targets. The `@` list mixes both kinds of name,
    /// and the kind decides the verb:
    ///
    ///   - **no name at all** → sweep every non-main worktree.
    ///   - a **repo** name (its directory name) → drop the whole repo, keeping
    ///     every worktree on disk. This is how you "return main": a repo's main
    ///     worktree cannot be deleted (git and `confirmAndDeleteWorktree` both
    ///     refuse), so naming the repo is the only sensible reading.
    ///   - a **branch** name of a linked worktree → delete that worktree.
    ///
    /// Repos win a name collision: dropping a repo leaves the worktree on disk,
    /// so guessing it is the recoverable mistake.
    static func resolveRemoveTarget(_ rest: String, worktrees: [CabinRef],
                                    repoPaths: [String]) -> Result<BridgeCommand, BridgeCommandError> {
        let first = rest.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let name = first.hasPrefix("@") ? String(first.dropFirst()) : first
        guard !name.isEmpty else { return .success(.removeAll) }
        if let path = repoPaths.first(where: {
            URL(fileURLWithPath: $0).lastPathComponent.lowercased() == name.lowercased()
        }) {
            return .success(.removeRepo(repoPath: path))
        }
        if let wt = worktrees.first(where: { $0.branch.lowercased() == name.lowercased() }) {
            return .success(.removeWorktree(worktreePath: wt.path))
        }
        return .failure(.unknownTarget(name))
    }

    /// Resolve a `#`-style argument to one item, by listing code or by name.
    ///
    /// A code is the 1-based position in the matching list command's output, so
    /// `/agents 2` picks whatever `/agents` just printed as `2.`. Codes are
    /// positional, not stable identifiers — they shift as the fleet changes, and
    /// they win over names, so an agent literally named "2" is reachable only by
    /// a later `names` entry.
    static func resolveIndexed<T>(_ arg: String, in items: [T], names: (T) -> [String]) -> T? {
        var cleaned = arg
        if cleaned.hasPrefix("#") || cleaned.hasPrefix("@") { cleaned = String(cleaned.dropFirst()) }
        guard !cleaned.isEmpty else { return nil }

        if let code = Int(cleaned), code >= 1, code <= items.count {
            return items[code - 1]
        }
        let lowered = cleaned.lowercased()
        return items.first { names($0).contains { $0.lowercased() == lowered } }
    }

    private static func agentNames(_ agent: AgentRef) -> [String] {
        [agent.branch, "\(agent.project)/\(agent.branch)", agent.project]
    }

    /// - Parameters:
    ///   - worktrees: what `/task` lists and `/task #x` selects from.
    ///   - agents: what `/agents` lists and `/agents #x` / `/order #x` select
    ///     from — the current worktree's panes, not the whole fleet.
    static func parse(_ text: String, worktrees: [CabinRef], agents: [AgentRef] = [],
                      repoPaths: [String] = []) -> Result<BridgeCommand, BridgeCommandError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyTask) }
        guard trimmed.hasPrefix("/") else {
            let (hint, task) = extractRepoHint(trimmed, repoPaths: repoPaths)
            return task.isEmpty ? .failure(.emptyTask) : .success(.newWorktree(task: task, repoHint: hint))
        }

        let body = String(trimmed.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let verb = (parts.first.map(String.init) ?? "").lowercased()
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        switch verb {
        case "worktree":
            if rest.isEmpty { return .success(.listWorktrees) }
            // `#` is what separates "go to that one" from "start this one", so a
            // description may never be mistaken for a selection.
            if rest.hasPrefix("#") {
                let arg = rest.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? rest
                guard let wt = resolveIndexed(arg, in: worktrees, names: { [$0.branch] }) else {
                    return .failure(.unknownTarget(String(arg.dropFirst())))
                }
                return .success(.selectWorktree(path: wt.path))
            }
            let (hint, task) = extractRepoHint(rest, repoPaths: repoPaths)
            return task.isEmpty ? .failure(.emptyTask) : .success(.newWorktree(task: task, repoHint: hint))

        case "pane", "panes":
            if rest.isEmpty { return .success(.listAgents) }
            guard let agent = resolveIndexed(rest, in: agents, names: agentNames) else {
                return .failure(.unknownTarget(rest))
            }
            return .success(.selectAgent(id: agent.id))

        case "order":
            let argParts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let target = argParts.first.map(String.init) else { return .failure(.missingArgument("order")) }
            guard let agent = resolveIndexed(target, in: agents, names: agentNames) else {
                return .failure(.unknownTarget(target.hasPrefix("#") ? String(target.dropFirst()) : target))
            }
            let task = argParts.count > 1 ? String(argParts[1]).trimmingCharacters(in: .whitespaces) : ""
            return task.isEmpty ? .failure(.emptyTask) : .success(.orderAgent(agentId: agent.id, task: task))

        case "broadcast":
            return rest.isEmpty ? .failure(.emptyTask) : .success(.broadcast(task: rest))

        case "add":
            return .success(.addRepo)

        case "return":
            return Self.resolveRemoveTarget(rest, worktrees: worktrees, repoPaths: repoPaths)

        case "feedback":
            return rest.isEmpty ? .failure(.emptyTask) : .success(.flagIssue(title: rest))

        default:
            return .failure(.unknownCommand(verb))
        }
    }
}

/// Renders the listings. Pure, so the numbering stays testable and stays in step
/// with `BridgeCommandParser.resolveIndexed`.
enum BridgeCommandFormatter {
    static func worktreeList(_ worktrees: [CabinRef], currentPath: String?) -> String {
        guard !worktrees.isEmpty else { return "No worktrees. `/worktree <description>` to start one." }
        let lines = worktrees.enumerated().map { index, wt in
            "\(index + 1). \(wt.repo) / \(wt.branch)\(wt.path == currentPath ? "  ← current" : "")"
        }
        return (["**Worktrees**", ""] + lines + ["", "`/worktree #<code|name>` to switch."]).joined(separator: "\n")
    }

    /// Every pane in the fleet, numbered, grouped under project and worktree.
    ///
    /// The chat surfaces list globally rather than per-worktree: neither a phone
    /// nor a mail thread has a tab bar to establish which worktree is meant, and
    /// the number printed here is what `/pane <n>` and `/order <n>` resolve
    /// against, so there must be exactly one numbering.
    static func fleetList(_ agents: [AgentRef], currentId: String?) -> String {
        guard !agents.isEmpty else { return "No panes running. `/worktree <description>` to start one." }
        var out = ["**Panes** — \(agents.count)", ""]
        var project: String?
        var branch: String?
        // The number is the 1-based position in this array, which is exactly
        // what `resolveIndexed` reads back — so the two can never disagree.
        for (offset, agent) in agents.enumerated() {
            if agent.project != project {
                out.append("**\(agent.project)**")
                project = agent.project
                branch = nil
            }
            if agent.branch != branch {
                out.append("  \(agent.branch)")
                branch = agent.branch
            }
            let here = agent.id == currentId ? "  ← current" : ""
            // A pane with no session title falls back to its branch, which the
            // line above already carries — and a shell pane's title is its whole
            // command line, which wraps for several lines and destroys the
            // alignment the numbering is read from.
            let label = agent.title == agent.branch ? "" : " — \(truncated(agent.title))"
            out.append("    \(offset + 1). \(agent.status.icon) \(agent.type)\(label)\(here)")
        }
        out.append("")
        out.append("`/pane <n>` opens one · `/order <n> <task>` sends without switching.")
        return out.joined(separator: "\n")
    }

    /// Keeps one listing row to one line. Shell panes carry their entire
    /// command line as a title.
    private static func truncated(_ title: String, limit: Int = 60) -> String {
        title.count <= limit ? title : "\(title.prefix(limit - 1))…"
    }

    /// One pane in full, and the note that this conversation now steers it.
    ///
    /// `transcript` is the session's own scrollback. It leads, because the
    /// status fields alone say almost nothing about what an agent has actually
    /// been doing — and for a pane that reports no structured events they are
    /// empty, which left the reply with nothing in it at all.
    static func paneDetail(_ agent: AgentRef, activity: [String], transcript: String?,
                           joined: String) -> String {
        var out = ["**\(agent.type) — \(truncated(agent.title, limit: 90))**",
                   "\(agent.project) / \(agent.branch) · \(agent.status.icon) \(agent.status.groupLabel)",
                   ""]
        if let transcript = transcript.map({ MailContentRedactor.summary($0, limit: 6_000) }),
           !transcript.isEmpty {
            out.append("**Session**")
            out.append(transcript)
            out.append("")
        }
        let message = MailContentRedactor.summary(agent.lastMessage, limit: 1_500)
        if !message.isEmpty {
            out.append("**Latest**")
            out.append(message)
            out.append("")
        }
        if !activity.isEmpty {
            out.append("**Recent activity**")
            out.append(contentsOf: activity.prefix(8).map { "· \($0)" })
            out.append("")
        }
        out.append(joined)
        return out.joined(separator: "\n")
    }

    static func agentList(_ agents: [AgentRef], currentId: String?) -> String {
        // The header reads off the first row rather than taking its own repo and
        // branch parameters, so it cannot disagree with the rows beneath it.
        guard let first = agents.first else { return "No panes in this worktree." }
        let lines = agents.enumerated().map { index, agent in
            "\(index + 1). \(agent.type) — \(agent.title)"
                + (agent.id == currentId ? "  ← current" : "")
        }
        return (["**Panes** - \(first.project) - \(first.branch)", ""]
                + lines
                + ["", "`/pane #<code>` to switch."]).joined(separator: "\n")
    }
}
