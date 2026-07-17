import Foundation

/// An agent as the chat commands see it.
struct AgentRef: Equatable {
    let id: String
    let project: String
    let branch: String
    let status: String
}

/// The chat-only verbs for browsing the fleet and pointing "current" at part of it.
enum ChatSelectionCommand: Equatable {
    case listRepos
    case listWorktrees
    case selectWorktree(path: String)
    case listAgents
    case selectAgent(id: String)
}

/// Pure parser for `/repo`, `/worktrees`, `/agents`. No IO, no singletons.
enum ChatSelectionParser {
    /// Returns nil when `text` isn't one of these verbs, so other parsers get a turn.
    static func parse(_ text: String, worktrees: [WorktreeRef],
                      agents: [AgentRef]) -> Result<ChatSelectionCommand, BridgeCommandError>? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let body = String(trimmed.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let verb = (parts.first.map(String.init) ?? "").lowercased()
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        switch verb {
        case "repo", "repos":
            // List-only: naming a repo has no "current repo" to point at.
            return .success(.listRepos)

        case "worktree", "worktrees":
            guard !rest.isEmpty else { return .success(.listWorktrees) }
            guard let wt = resolve(rest, in: worktrees, names: { [$0.branch] }) else {
                return .failure(.unknownTarget(rest))
            }
            return .success(.selectWorktree(path: wt.path))

        case "agent", "agents":
            guard !rest.isEmpty else { return .success(.listAgents) }
            guard let agent = resolve(rest, in: agents,
                                      names: { [$0.branch, "\($0.project)/\($0.branch)", $0.project] }) else {
                return .failure(.unknownTarget(rest))
            }
            return .success(.selectAgent(id: agent.id))

        default:
            return nil
        }
    }

    /// Resolve an argument to one item, by listing code or by name.
    ///
    /// A code is the 1-based position in the matching list command's output, so
    /// `/agents 2` picks whatever `/agents` just printed as `2.`. Codes are
    /// positional, not stable identifiers — they shift as the fleet changes.
    ///
    /// Codes win over names: a branch named "2" is reachable, but only by an
    /// earlier `names` entry, never by the bare digit.
    private static func resolve<T>(_ arg: String, in items: [T],
                                   names: (T) -> [String]) -> T? {
        let cleaned = arg.hasPrefix("@") ? String(arg.dropFirst()) : arg
        guard !cleaned.isEmpty else { return nil }

        if let code = Int(cleaned), code >= 1, code <= items.count {
            return items[code - 1]
        }

        let lowered = cleaned.lowercased()
        return items.first { names($0).contains { $0.lowercased() == lowered } }
    }
}

/// Renders the listings. Pure, so the numbering stays testable and stays in step
/// with `ChatSelectionParser.resolve`.
enum ChatSelectionFormatter {
    static func repoList(_ repoPaths: [String]) -> String {
        guard !repoPaths.isEmpty else { return "No repos configured. Use `/add` on the desktop." }
        let lines = repoPaths.enumerated().map { index, path in
            "\(index + 1). \(URL(fileURLWithPath: path).lastPathComponent)"
        }
        return (["**Repos**", ""] + lines).joined(separator: "\n")
    }

    static func worktreeList(_ worktrees: [WorktreeRef], currentPath: String?) -> String {
        guard !worktrees.isEmpty else { return "No worktrees." }
        let lines = worktrees.enumerated().map { index, wt in
            "\(index + 1). \(wt.branch)\(wt.path == currentPath ? "  ← current" : "")"
        }
        return (["**Worktrees**", ""] + lines
            + ["", "`/worktrees <code|name>` to switch."]).joined(separator: "\n")
    }

    static func agentList(_ agents: [AgentRef], currentId: String?) -> String {
        guard !agents.isEmpty else { return "No agents registered." }
        let lines = agents.enumerated().map { index, agent in
            "\(index + 1). \(agent.project) / \(agent.branch) — \(agent.status)"
                + (agent.id == currentId ? "  ← current" : "")
        }
        return (["**Agents**", ""] + lines
            + ["", "`/agents <code|name>` to switch."]).joined(separator: "\n")
    }
}
