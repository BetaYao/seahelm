import Foundation

/// Renders listings, details and errors. Pure, so the wording is testable and
/// identical on every surface.
enum CommandFormatter {
    // MARK: - Targets

    /// `#7 seahelm/main` — how every reply names a pane.
    static func target(_ pane: PaneRef) -> String {
        "#\(pane.handle) \(pane.project)/\(pane.branch)"
    }

    // MARK: - Listings

    /// Every pane, grouped under repo and worktree, each with its handle.
    static func panes(_ index: FleetIndex, bound: PaneRef?) -> String {
        guard !index.panes.isEmpty else { return "No panes running. `/new <task>` to start one." }
        // Grouped by worktree, not by branch: two worktrees can carry the same
        // branch name, and one on a detached HEAD carries none at all.
        let sorted = index.panes.sorted {
            ($0.project.lowercased(), $0.worktreePath.lowercased(), $0.handle)
                < ($1.project.lowercased(), $1.worktreePath.lowercased(), $1.handle)
        }
        var out = ["**Panes** — \(sorted.count)", ""]
        var project: String?
        var worktreePath: String?
        for pane in sorted {
            if pane.project != project {
                out.append("**\(pane.project)**")
                project = pane.project
                worktreePath = nil
            }
            if pane.worktreePath != worktreePath {
                out.append("  \(WorktreeRef.name(branch: pane.branch, path: pane.worktreePath))")
                worktreePath = pane.worktreePath
            }
            // A pane with no title of its own falls back to its branch, which
            // the line above already carries; a shell pane's title is its whole
            // command line, which would wrap and wreck the alignment.
            let group = WorktreeRef.name(branch: pane.branch, path: pane.worktreePath)
            let label = (pane.title.isEmpty || pane.title == group) ? "" : " — \(truncated(pane.title))"
            let here = pane.handleKey == bound?.handleKey ? "  ← talking to this one" : ""
            out.append("    #\(pane.handle) \(pane.status.icon) \(pane.type)\(label)\(here)")
        }
        out.append("")
        out.append("`/go #n` to talk to one · `/order #n <text>` sends without switching.")
        return out.joined(separator: "\n")
    }

    static func worktrees(_ index: FleetIndex, bound: PaneRef?) -> String {
        guard !index.worktrees.isEmpty else { return "No worktrees. `/new <task>` to start one." }
        let sorted = index.worktrees.sorted {
            ($0.repo.lowercased(), $0.isMain ? 0 : 1, $0.branch.lowercased())
                < ($1.repo.lowercased(), $1.isMain ? 0 : 1, $1.branch.lowercased())
        }
        var out = ["**Worktrees** — \(sorted.count)", ""]
        var repo: String?
        for wt in sorted {
            if wt.repo != repo {
                out.append("**\(wt.repo)**")
                repo = wt.repo
            }
            let panes = index.panes(inWorktree: wt.path)
            let count = panes.isEmpty ? "no panes"
                : "\(panes.count) pane\(panes.count == 1 ? "" : "s") \(panes.map(\.status.icon).joined())"
            let here = bound.map { $0.worktreePath == wt.path } == true ? "  ← here" : ""
            out.append("  \(index.label(for: wt))  ·  \(count)\(here)")
        }
        out.append("")
        out.append("`/go @name` to talk to one · `/return @name` deletes it.")
        return out.joined(separator: "\n")
    }

    static func repos(_ index: FleetIndex) -> String {
        guard !index.repos.isEmpty else { return "No repos. Add one on the desktop." }
        var out = ["**Repos** — \(index.repos.count)", ""]
        for repo in index.repos.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            let count = index.worktrees.filter { $0.repo == repo.name }.count
            out.append("  @\(repo.name)  ·  \(count) worktree\(count == 1 ? "" : "s")  ·  \(repo.path)")
        }
        out.append("")
        out.append("`/new @name <task>` starts a worktree there · `/forget @name` drops it.")
        return out.joined(separator: "\n")
    }

    // MARK: - Listing buttons

    /// How many buttons a listing offers. A fleet of thirty panes would bury
    /// the listing itself under its own shortcuts, and the text above them is
    /// complete either way — `/go #24` still works for the ones left out.
    static let buttonLimit = 8

    /// `/go` for each pane a `/status` listing showed, newest handles first.
    /// The pane already being talked to is left out: its button would do
    /// nothing.
    static func paneButtons(_ index: FleetIndex, bound: PaneRef?) -> [CommandButton] {
        index.panes
            .filter { $0.handleKey != bound?.handleKey }
            .sorted { $0.handle > $1.handle }
            .prefix(buttonLimit)
            .map { pane in
                CommandButton.line("\(pane.status.icon) #\(pane.handle) \(pane.branch)",
                                   "/go #\(pane.handle)")
            }
    }

    /// `/go` for each worktree a `/status worktrees` listing showed. Worktrees
    /// with no pane are skipped — `/go` there has nothing to talk to.
    static func worktreeButtons(_ index: FleetIndex, bound: PaneRef?) -> [CommandButton] {
        index.worktrees
            .filter { $0.path != bound?.worktreePath && !index.panes(inWorktree: $0.path).isEmpty }
            .sorted { ($0.repo.lowercased(), $0.name.lowercased()) < ($1.repo.lowercased(), $1.name.lowercased()) }
            .prefix(buttonLimit)
            .map { wt in
                let label = index.label(for: wt)
                return CommandButton.line(String(label.dropFirst()), "/go \(label)")
            }
    }

    /// Keeps one listing row to one line.
    static func truncated(_ title: String, limit: Int = 60) -> String {
        title.count <= limit ? title : "\(title.prefix(limit - 1))…"
    }

    // MARK: - Detail

    /// One pane in full. The transcript leads: the status fields alone say
    /// almost nothing about what an agent has been doing, and for a pane
    /// that reports no structured events they are empty.
    static func paneDetail(_ pane: PaneRef, activity: [String], transcript: String?, footer: String?) -> String {
        var out = ["**\(target(pane))** · \(pane.type) — \(truncated(pane.title, limit: 90))",
                   "\(pane.status.icon) \(pane.status.groupLabel)",
                   ""]
        if let transcript = transcript.map({ MailContentRedactor.summary($0, limit: 6_000) }),
           !transcript.isEmpty {
            out.append("**Session**")
            out.append(transcript)
            out.append("")
        }
        let message = MailContentRedactor.summary(pane.lastMessage, limit: 1_500)
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
        if let footer, !footer.isEmpty { out.append(footer) }
        return out.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    // MARK: - Errors

    // MARK: - /return

    static func returnOutcome(_ outcome: WorktreeReturnOutcome, label: String) -> CommandReply {
        if let failure = outcome.failure {
            var lines = ["\(label): \(failure)"]
            if let url = outcome.prURL { lines.append("PR: \(url)") }
            lines.append("The worktree stays.")
            return CommandReply(lines.joined(separator: "\n"), isError: true, presentsOnDesktop: true)
        }
        var lines: [String] = []
        if let url = outcome.prURL { lines.append("Opened PR: \(url)") }
        lines.append(contentsOf: outcome.notes.map { "Note: \($0)" })
        if outcome.deletesWorktree {
            lines.append("Returned \(label)." + (outcome.deletesBranch ? " Branch deleted." : ""))
        } else {
            lines.append("\(label) stays.")
        }
        // A row disappearing is its own report; a PR link or a hold is not.
        let worthShowing = outcome.prURL != nil || !outcome.notes.isEmpty || !outcome.deletesWorktree
        return CommandReply(lines.joined(separator: "\n"), presentsOnDesktop: worthShowing)
    }

    static func sweepReport(returned: [String], remaining: [String]) -> String {
        var lines: [String] = []
        if returned.isEmpty {
            lines.append("Nothing had finished cleanly.")
        } else {
            lines.append("Returned \(returned.count) worktree\(returned.count == 1 ? "" : "s"): \(returned.joined(separator: ", ")).")
        }
        if !remaining.isEmpty {
            lines.append("")
            lines.append("Still here:")
            lines.append(contentsOf: remaining)
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ error: CommandError) -> String {
        switch error {
        case .empty:
            return "Nothing to do."
        case .unknownCommand(let verb):
            return "Unknown command `/\(verb)`. `/help` lists them."
        case .badPaneRef(let token):
            return "`\(token)` is not a pane. Panes are `#` and a number — `/status` lists them."
        case .unknownPane(let handle):
            return "No pane #\(handle). `/status` to see what's running."
        case .unknownWorktree(let name):
            return "No worktree `@\(name)`. `/status worktrees` lists them."
        case .ambiguousWorktree(let name, let options):
            return "`@\(name)` is in several repos: \(options.map { "`@\($0)`" }.joined(separator: ", ")). Say which."
        case .repoNotWorktree(let name):
            return "`@\(name)` is a repo, not a worktree. `/forget @\(name)` drops it; `/return` only takes worktrees."
        case .unknownRepo(let name):
            return "No repo `@\(name)`. `/status repos` lists them."
        case .worktreeNotRepo(let name):
            return "`@\(name)` is a worktree, not a repo. `/return @\(name)` deletes it."
        case .missingArgument(let verb, let what):
            return "`/\(verb)` needs \(what).\(usageHint(verb))"
        case .badArgument(let verb, let token):
            return "`/\(verb)` doesn't take `\(token)`.\(usageHint(verb))"
        case .cannotReturnMain(let label):
            return "`\(label)` is a main worktree — it can't be returned. `/forget @repo` drops the whole repo instead."
        }
    }

    private static func usageHint(_ verb: String) -> String {
        guard let spec = CommandSpecs.spec(for: verb) else { return "" }
        return " Usage: `\(spec.usage)`"
    }
}
