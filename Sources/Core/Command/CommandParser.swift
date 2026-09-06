import Foundation

/// Pure parser: text + the fleet it can name → one `ParsedLine`. No IO.
enum CommandParser {
    /// Verbs whose trailing `force` means "skip the question". Only these
    /// strip it, so a `/order` whose text happens to end in the word keeps it.
    private static let forceable: Set<String> = ["return", "forget", "broadcast", "integrate", "remove"]

    static func parse(_ text: String, index: FleetIndex) -> Result<ParsedLine, CommandError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.hasPrefix("/") else { return .success(ParsedLine(.say(trimmed))) }

        let body = trimmed.dropFirst()
        let parts = body.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        let verb = parts.first.map { String($0).lowercased() } ?? ""
        guard !verb.isEmpty else { return .failure(.unknownCommand("/")) }
        var rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

        var force = false
        if forceable.contains(verb) {
            (rest, force) = stripForce(rest)
        }

        return parseVerb(verb, rest: rest, index: index).map { ParsedLine($0, force: force) }
    }

    // MARK: - Verbs

    private static func parseVerb(_ verb: String, rest: String, index: FleetIndex) -> Result<Command, CommandError> {
        switch verb {
        case "new":
            return parseNew(rest, index: index)

        case "go":
            guard let token = firstToken(rest) else {
                return .failure(.missingArgument(verb: "go", what: "a `#pane` or `@worktree`"))
            }
            return goTarget(token, index: index).map(Command.go)

        case "show":
            guard let token = firstToken(rest) else { return .success(.show(nil)) }
            return paneRef(token, index: index).map { .show($0) }

        case "order":
            let (head, tail) = splitFirst(rest)
            guard let head else { return .failure(.missingArgument(verb: "order", what: "a `#pane` and the text")) }
            return paneRef(head, index: index).flatMap { pane in
                tail.isEmpty ? .failure(.missingArgument(verb: "order", what: "the text to send"))
                             : .success(.order(pane, tail))
            }

        case "broadcast":
            return rest.isEmpty ? .failure(.missingArgument(verb: "broadcast", what: "the text to send"))
                                : .success(.broadcast(rest))

        case "status":
            switch firstToken(rest)?.lowercased() {
            case nil, "panes", "pane":          return .success(.status(.panes))
            case "worktrees", "worktree":       return .success(.status(.worktrees))
            case "repos", "repo", "projects":   return .success(.status(.repos))
            case .some(let other):              return .failure(.badArgument(verb: "status", token: other))
            }

        case "return", "remove":
            guard let token = firstToken(rest) else { return .success(.returnAll) }
            return worktreeRef(token, index: index).flatMap { wt in
                wt.isMain ? .failure(.cannotReturnMain(index.label(for: wt))) : .success(.returnWorktree(wt))
            }

        case "forget":
            guard let token = firstToken(rest) else {
                return .failure(.missingArgument(verb: "forget", what: "a `@repo`"))
            }
            return repoRef(token, index: index).map(Command.forget)

        case "integrate":
            var mode = IntegrationConflictMode.excludeConflicting
            for token in rest.split(whereSeparator: \.isWhitespace) {
                switch token.lowercased() {
                case "full":  mode = .includeWithMarkers
                case "clean": mode = .excludeConflicting
                // A typo must not quietly drop someone's conflicting work.
                default:      return .failure(.badArgument(verb: "integrate", token: String(token)))
                }
            }
            return .success(.integrate(mode: mode))

        case "idea":
            return rest.isEmpty ? .failure(.missingArgument(verb: "idea", what: "the idea")) : .success(.idea(rest))

        case "feedback":
            return rest.isEmpty ? .failure(.missingArgument(verb: "feedback", what: "a description")) : .success(.feedback(rest))

        case "help":
            guard let token = firstToken(rest) else { return .success(.help(nil)) }
            let name = token.hasPrefix("/") ? String(token.dropFirst()) : token
            return .success(.help(name.lowercased()))

        case "yes":
            return .success(.yes)

        case "add":
            return .success(.add)

        // MARK: Legacy spellings — one release, then gone.

        case "worktree":
            // `#`/`@` selected; anything else was a description to start.
            guard let token = firstToken(rest) else { return .success(.status(.worktrees)) }
            if token.hasPrefix("#") || token.hasPrefix("@"), rest == token {
                return goTarget(token, index: index).map(Command.go)
            }
            return parseNew(rest, index: index)

        case "pane", "panes":
            guard let token = firstToken(rest) else { return .success(.status(.panes)) }
            return goTarget(token, index: index).map(Command.go)

        default:
            return .failure(.unknownCommand(verb))
        }
    }

    private static func parseNew(_ rest: String, index: FleetIndex) -> Result<Command, CommandError> {
        guard !rest.isEmpty else { return .failure(.missingArgument(verb: "new", what: "a task")) }
        var repo: RepoRef?
        var task = rest
        if rest.hasPrefix("@") {
            let (head, tail) = splitFirst(rest)
            switch repoRef(head ?? "", index: index) {
            case .failure(let error): return .failure(error)
            case .success(let hit):
                repo = hit
                task = tail
            }
        }
        guard !task.isEmpty else { return .failure(.missingArgument(verb: "new", what: "a task")) }
        return .success(.new(task: task, repo: repo))
    }

    // MARK: - References

    /// `#7`, or a bare number. Anything else is not a pane.
    static func paneRef(_ token: String, index: FleetIndex) -> Result<PaneRef, CommandError> {
        let digits = token.hasPrefix("#") ? String(token.dropFirst()) : token
        guard let handle = Int(digits), handle > 0 else { return .failure(.badPaneRef(token)) }
        guard let pane = index.pane(handle: handle) else { return .failure(.unknownPane(handle)) }
        return .success(pane)
    }

    /// `@branch`, `@repo/branch`, or the bare name.
    static func worktreeRef(_ token: String, index: FleetIndex) -> Result<WorktreeRef, CommandError> {
        let name = token.hasPrefix("@") ? String(token.dropFirst()) : token
        guard !name.isEmpty else { return .failure(.unknownWorktree(token)) }
        return index.worktree(named: name)
    }

    /// `@repo` or the bare name.
    static func repoRef(_ token: String, index: FleetIndex) -> Result<RepoRef, CommandError> {
        let name = token.hasPrefix("@") ? String(token.dropFirst()) : token
        guard !name.isEmpty else { return .failure(.unknownRepo(token)) }
        if let repo = index.repo(named: name) { return .success(repo) }
        if case .success = index.worktree(named: name) { return .failure(.worktreeNotRepo(name)) }
        return .failure(.unknownRepo(name))
    }

    /// `/go` takes either kind. The sigil decides; a bare number is a pane and
    /// a bare name a worktree, since the two can never collide.
    private static func goTarget(_ token: String, index: FleetIndex) -> Result<GoTarget, CommandError> {
        if token.hasPrefix("#") || Int(token) != nil {
            return paneRef(token, index: index).map(GoTarget.pane)
        }
        return worktreeRef(token, index: index).map(GoTarget.worktree)
    }

    // MARK: - Tokens

    private static func firstToken(_ text: String) -> String? {
        text.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            .first.map(String.init)
    }

    private static func splitFirst(_ text: String) -> (String?, String) {
        let parts = text.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard let head = parts.first else { return (nil, "") }
        let tail = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return (String(head), tail)
    }

    /// Drops a trailing `force` word. Suffix-based rather than re-joined, so
    /// the text in front keeps its own spacing.
    private static func stripForce(_ rest: String) -> (String, Bool) {
        let lowered = rest.lowercased()
        if lowered == "force" { return ("", true) }
        if lowered.hasSuffix(" force") {
            return (String(rest.dropLast(" force".count)).trimmingCharacters(in: .whitespaces), true)
        }
        return (rest, false)
    }
}
