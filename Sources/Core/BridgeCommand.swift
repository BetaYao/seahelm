import Foundation

struct WorktreeRef: Equatable {
    let branch: String
    let path: String
}

enum BridgeCommand: Equatable {
    case newWorktree(task: String)
    case orderExisting(worktreePath: String, task: String)
    case commit(worktreePath: String)
    case returnToPort(worktreePath: String)
    case broadcast(task: String)
}

enum BridgeCommandError: Error, Equatable {
    case emptyTask
    case unknownCommand(String)
    case unknownBranch(String)
    case missingArgument(String)
}

/// Pure parser: text + worktree list → BridgeCommand or error. No IO, no singletons.
enum BridgeCommandParser {
    static func parse(_ text: String, worktrees: [WorktreeRef]) -> Result<BridgeCommand, BridgeCommandError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyTask) }
        guard trimmed.hasPrefix("/") else { return .success(.newWorktree(task: trimmed)) }

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
            return rest.isEmpty ? .failure(.emptyTask) : .success(.newWorktree(task: rest))
        case "order":
            return resolveBranch("order").flatMap { r in
                r.tail.isEmpty ? .failure(.emptyTask) : .success(.orderExisting(worktreePath: r.path, task: r.tail))
            }
        case "commit":
            return resolveBranch("commit").map { .commit(worktreePath: $0.path) }
        case "return":
            return resolveBranch("return").map { .returnToPort(worktreePath: $0.path) }
        case "broadcast":
            return rest.isEmpty ? .failure(.emptyTask) : .success(.broadcast(task: rest))
        default:
            return .failure(.unknownCommand(verb))
        }
    }
}
