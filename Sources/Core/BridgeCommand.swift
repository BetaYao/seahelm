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
    /// Repo and branch are the same for every agent in one listing — it lists a
    /// single worktree's agents — so they head the reply rather than repeat on
    /// every row.
    let project: String
    let branch: String
    /// Agent kind, e.g. "Claude".
    let type: String
    /// This agent's own session title. Distinct per agent, unlike the
    /// worktree-keyed title the dashboard shows.
    let title: String
}

/// The command language, spoken identically by the desktop Helm line and the
/// chat channel.
///
/// Two sigils, and they are not interchangeable:
///   - `@name` picks a **repo** (`/task @seahelm …`) or, for `/return`, a repo
///     or a branch.
///   - `#code|name` picks an existing **worktree** (`/task #2`) or **agent**
///     (`/order #1 …`). It is what disambiguates selecting from creating:
///     `/task fix login` starts work, `/task #3` moves to it.
enum BridgeCommand: Equatable {
    /// `/task` — every worktree, numbered.
    case listWorktrees
    /// `/task [@repo] <description>` — start a worktree and make it current.
    case newWorktree(task: String, repoHint: String? = nil)
    /// `/task #<code|branch>` — make an existing worktree current.
    case selectWorktree(path: String)
    /// `/agents` — every agent in the current worktree, numbered.
    case listAgents
    /// `/agents #<code|name>` — make one of them current.
    case selectAgent(id: String)
    /// `/order #<code|name> <task>` — send to one agent without moving current.
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
    /// `/flag <description>` — open a GitHub issue pre-filled with the description.
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
        case "task":
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

        case "agent", "agents":
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

        case "flag":
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
        guard !worktrees.isEmpty else { return "No tasks. `/task <description>` to start one." }
        let lines = worktrees.enumerated().map { index, wt in
            "\(index + 1). \(wt.repo) / \(wt.branch)\(wt.path == currentPath ? "  ← current" : "")"
        }
        return (["**Tasks**", ""] + lines + ["", "`/task #<code|name>` to switch."]).joined(separator: "\n")
    }

    static func agentList(_ agents: [AgentRef], currentId: String?) -> String {
        // The header reads off the first row rather than taking its own repo and
        // branch parameters, so it cannot disagree with the rows beneath it.
        guard let first = agents.first else { return "No agents in this task." }
        let lines = agents.enumerated().map { index, agent in
            "\(index + 1). \(agent.type) — \(agent.title)"
                + (agent.id == currentId ? "  ← current" : "")
        }
        return (["**Agents** - \(first.project) - \(first.branch)", ""]
                + lines
                + ["", "`/agents #<code>` to switch."]).joined(separator: "\n")
    }
}
