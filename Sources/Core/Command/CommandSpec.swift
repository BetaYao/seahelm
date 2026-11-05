import Foundation

/// One verb, described once.
///
/// This table is the single source of truth for the command language: the
/// parser accepts exactly these verbs, `/help` prints them, the Helm line
/// completes them. Two of those used to be
/// hand-written copies, and they had drifted.
struct CommandSpec: Equatable {
    let verb: String
    /// `/new [@repo] <task>` — the shape, for help and error messages.
    let usage: String
    /// One line, for the table.
    let summary: String
    /// A short paragraph, for `/help <verb>`.
    let detail: String
    /// Asks before acting: a sheet on the desktop, `/yes` in chat.
    let confirms: Bool
    /// Needs the desktop (a file picker, a window); chat only gets a hint.
    let desktopOnly: Bool

    init(verb: String, usage: String, summary: String, detail: String,
         confirms: Bool = false, desktopOnly: Bool = false) {
        self.verb = verb
        self.usage = usage
        self.summary = summary
        self.detail = detail
        self.confirms = confirms
        self.desktopOnly = desktopOnly
    }
}

enum CommandSpecs {
    /// The language as cut on 2026-11-04 (docs/command-redesign.md §0): run by
    /// seahelm-core (`command.run`); this table names it for the Helm menu.
    static let all: [CommandSpec] = [
        CommandSpec(
            verb: "go", usage: "/go #pane | @worktree | mate",
            summary: "Talk to a pane, a worktree's pane, or First Mate from now on",
            detail: "Changes who this conversation talks to: anything you say without a slash goes there. `/go mate` talks to First Mate. Bare `/go` says who it is now. Only this conversation changes."),
        CommandSpec(
            verb: "new", usage: "/new [@repo] <task>",
            summary: "Start a worktree with an agent on the task, and talk to it",
            detail: "Creates a worktree in the repo (the first one when `@repo` is left out), starts an agent on the task, and talks to it from now on."),
        CommandSpec(
            verb: "status", usage: "/status",
            summary: "The fleet, with handles",
            detail: "Every pane, grouped by repo and worktree, with its `#handle`, status and title; worktrees without a pane too. Marks the one you are talking to."),
        CommandSpec(
            verb: "show", usage: "/show [#pane]",
            summary: "What a pane is doing",
            detail: "The pane's latest turn and its reply. Read-only. Bare `/show` reads the pane you are talking to."),
        CommandSpec(
            verb: "notes", usage: "/notes [undo] @repo",
            summary: "A project's notes (First Mate's project memory); undo the last change",
            detail: "`/notes @repo` shows what First Mate remembers about the project and what every new agent there is told. `/notes undo @repo` restores the previous version. Not `/memory`: that is Claude Code's own command."),
        CommandSpec(
            verb: "help", usage: "/help [command]",
            summary: "This list; with a command, its details",
            detail: "You are reading it."),
    ]

    /// Old spellings the parser still accepts for one release. Not listed.
    static let legacyVerbs: Set<String> = ["worktree", "pane", "panes", "remove"]

    static func spec(for verb: String) -> CommandSpec? {
        let needle = verb.lowercased()
        return all.first { $0.verb == needle }
    }

    static let addressing = "`#7` is a pane. `@branch` (or `@repo/branch`) is a worktree; `@repo` is a repo."
    static let proseLine = "Anything without a slash goes to whoever you are talking to."

    /// The full table, as `/help` prints it. A chat leaves out what only the
    /// desktop can run.
    static func help(desktop: Bool) -> String {
        var lines = ["**Commands**", "", "`<anything>` — \(proseLine)"]
        for spec in all where desktop || !spec.desktopOnly {
            var line = "`\(spec.usage)` — \(spec.summary)"
            if spec.confirms { line += " · asks first" }
            lines.append(line)
        }
        lines.append("")
        lines.append(addressing)
        return lines.joined(separator: "\n")
    }

    /// `/help <verb>`; nil for a verb that does not exist.
    static func help(for verb: String) -> String? {
        guard let spec = spec(for: verb) else { return nil }
        var lines = ["`\(spec.usage)`", spec.detail]
        if spec.confirms { lines.append("Asks before acting; `/yes` to go ahead, or append `force`.") }
        if spec.desktopOnly { lines.append("Desktop only.") }
        return lines.joined(separator: "\n")
    }

    /// The Helm line's `/` menu: verb and a one-liner.
    static var menu: [(name: String, desc: String)] {
        all.filter { $0.verb != "yes" }.map { ($0.verb, $0.summary) }
    }
}
