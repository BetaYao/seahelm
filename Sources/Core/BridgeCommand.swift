import Foundation

struct WorktreeRef: Equatable {
    let branch: String
    let path: String
}

enum BridgeCommand: Equatable {
    case newWorktree(task: String, repoHint: String? = nil)
    case orderExisting(worktreePath: String, task: String)
    case commit(worktreePath: String)
    case returnToPort(worktreePath: String)
    case returnAll
    case broadcast(task: String)
    case addRepo
    /// Stop tracking a repo: kills its sessions, leaves every worktree on disk.
    case removeRepo(repoPath: String)
    /// Delete one linked worktree (never the main one — that is `removeRepo`).
    case removeWorktree(worktreePath: String)
}

enum BridgeCommandError: Error, Equatable {
    case emptyTask
    case unknownCommand(String)
    case unknownBranch(String)
    case unknownTarget(String)
    case missingArgument(String)
}

/// Pure parser: text + worktree list → BridgeCommand or error. No IO, no singletons.
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

    /// Resolve what `/remove @x` targets. The `@` list mixes both kinds of name,
    /// and the kind decides the verb:
    ///
    ///   - a **repo** name (its directory name) → drop the whole repo, keeping
    ///     every worktree on disk. This is how you "remove main": a repo's main
    ///     worktree cannot be deleted (git and `confirmAndDeleteWorktree` both
    ///     refuse), so naming the repo is the only sensible reading.
    ///   - a **branch** name of a linked worktree → delete that worktree.
    ///
    /// Repos win a name collision: dropping a repo leaves the worktree on disk,
    /// so guessing it is the recoverable mistake.
    static func resolveRemoveTarget(_ rest: String, worktrees: [WorktreeRef],
                                    repoPaths: [String]) -> Result<BridgeCommand, BridgeCommandError> {
        let first = rest.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let name = first.hasPrefix("@") ? String(first.dropFirst()) : first
        guard !name.isEmpty else { return .failure(.missingArgument("remove")) }
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

    static func parse(_ text: String, worktrees: [WorktreeRef],
                      repoPaths: [String] = []) -> Result<BridgeCommand, BridgeCommandError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyTask) }
        guard trimmed.hasPrefix("/") else {
            let (hint, task) = extractRepoHint(trimmed, repoPaths: repoPaths)
            return task.isEmpty ? .failure(.emptyTask) : .success(.newWorktree(task: task, repoHint: hint))
        }

        let body = String(trimmed.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let verb = parts.first.map(String.init) ?? ""
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        func resolveBranch(_ verbName: String) -> Result<(path: String, tail: String), BridgeCommandError> {
            let argParts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let branch = argParts.first.map(String.init) else { return .failure(.missingArgument(verbName)) }
            guard let wt = worktrees.first(where: { $0.branch == branch }) else { return .failure(.unknownBranch(branch)) }
            let tail = argParts.count > 1 ? String(argParts[1]).trimmingCharacters(in: .whitespaces) : ""
            return .success((wt.path, tail))
        }

        switch verb {
        case "new":
            if rest.isEmpty { return .failure(.emptyTask) }
            let (hint, task) = extractRepoHint(rest, repoPaths: repoPaths)
            return task.isEmpty ? .failure(.emptyTask) : .success(.newWorktree(task: task, repoHint: hint))
        case "order":
            return resolveBranch("order").flatMap { r in
                r.tail.isEmpty ? .failure(.emptyTask) : .success(.orderExisting(worktreePath: r.path, task: r.tail))
            }
        case "commit":
            return resolveBranch("commit").map { .commit(worktreePath: $0.path) }
        case "return":
            if rest.isEmpty { return .success(.returnAll) }
            return resolveBranch("return").map { .returnToPort(worktreePath: $0.path) }
        case "broadcast":
            return rest.isEmpty ? .failure(.emptyTask) : .success(.broadcast(task: rest))
        case "add":
            return .success(.addRepo)
        case "remove":
            return Self.resolveRemoveTarget(rest, worktrees: worktrees, repoPaths: repoPaths)
        default:
            return .failure(.unknownCommand(verb))
        }
    }
}
