import Foundation

/// One verb, described once.
///
/// This table is the single source of truth for the command language: the
/// parser accepts exactly these verbs, `/help` prints them, the Helm line
/// completes them and the mail signature lists them. Two of those used to be
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
    static let all: [CommandSpec] = [
        CommandSpec(
            verb: "new", usage: "/new [@repo] <task>",
            summary: "Start a worktree with an agent on the task, and talk to it",
            detail: "Creates a worktree in the repo (the first one when `@repo` is left out), starts an agent on the task, and binds this conversation to the new pane, so what you say next goes to it."),
        CommandSpec(
            verb: "go", usage: "/go #pane | @worktree",
            summary: "Talk to this pane from now on",
            detail: "Binds this conversation to a pane, or to a worktree's pane. Only this conversation changes: a phone's `/go` does not move the desktop. On the desktop it selects the pane."),
        CommandSpec(
            verb: "show", usage: "/show [#pane]",
            summary: "Read a pane's recent output",
            detail: "The pane's session transcript, latest message and recent tool activity. Read-only — it does not change who you are talking to. Bare `/show` reads the bound pane."),
        CommandSpec(
            verb: "order", usage: "/order #pane <text>",
            summary: "Send one pane a message without switching to it",
            detail: "Types the text into that pane and presses Enter. Your binding stays where it was."),
        CommandSpec(
            verb: "broadcast", usage: "/broadcast <text>",
            summary: "Send every pane the same message",
            detail: "Lists the panes it would reach and asks first.",
            confirms: true),
        CommandSpec(
            verb: "status", usage: "/status [worktrees|repos]",
            summary: "The fleet, with handles",
            detail: "Bare `/status` lists every pane, grouped by repo and worktree, with its `#handle`, status and title, and marks the one you are talking to. `worktrees` and `repos` list the tiers above."),
        CommandSpec(
            verb: "return", usage: "/return [@worktree]",
            summary: "Finish a worktree: ship what it has, then delete it",
            detail: "`/return @worktree` measures the branch against its base on origin. Nothing to ship — clean, every change already merged — and it deletes the worktree and branch outright. Otherwise it says what it will do and asks: commit any uncommitted changes, push the branch, open a PR on GitHub (skipped with a note when there is no token or origin is not GitHub), then delete. A step failing leaves the worktree in place. It refuses while an agent is running there. Bare `/return` does this for every linked worktree but only deletes the ones with nothing to ship; the rest are listed with their plans. A repo's main worktree cannot be returned; `/forget @repo` drops the repo instead.",
            confirms: true),
        CommandSpec(
            verb: "forget", usage: "/forget @repo",
            summary: "Stop tracking a repo; its worktrees stay on disk",
            detail: "Removes the repo from seahelm and kills its persisted sessions. Nothing on disk is touched.",
            confirms: true),
        CommandSpec(
            verb: "integrate", usage: "/integrate [full]",
            summary: "Run one integration round for the current repo",
            detail: "Folds every worktree in the repo onto trunk and checks the result out in the integration worktree. `full` keeps conflicting worktrees with markers instead of dropping them. If local edits in the checkout hold the round back, it asks before discarding them.",
            confirms: true),
        CommandSpec(
            verb: "idea", usage: "/idea <text>",
            summary: "Capture an idea",
            detail: "Adds it to the idea list with this conversation as its source."),
        CommandSpec(
            verb: "feedback", usage: "/feedback <text>",
            summary: "Open a GitHub issue for seahelm",
            detail: "Opens a pre-filled issue in the browser."),
        CommandSpec(
            verb: "help", usage: "/help [command]",
            summary: "This list; with a command, its details",
            detail: "You are reading it."),
        CommandSpec(
            verb: "yes", usage: "/yes",
            summary: "Go ahead with the action that just asked",
            detail: "Confirms the pending action in this conversation. It expires after 60 seconds, and any other message cancels it. Appending `force` to a command skips the question — for scripts and mail, where a round trip is slow."),
        CommandSpec(
            verb: "add", usage: "/add",
            summary: "Add a repo (desktop only)",
            detail: "Opens the file picker. There is no chat equivalent.",
            desktopOnly: true),
    ]

    /// Old spellings the parser still accepts for one release. Not listed.
    static let legacyVerbs: Set<String> = ["worktree", "pane", "panes", "remove"]

    static func spec(for verb: String) -> CommandSpec? {
        let needle = verb.lowercased()
        return all.first { $0.verb == needle }
    }

    static let addressing = "`#7` is a pane. `@branch` (or `@repo/branch`) is a worktree; `@repo` is a repo."
    static let proseLine = "Anything without a slash goes to the pane you are talking to."

    /// The full table, as `/help` prints it.
    static var help: String {
        var lines = ["**Commands**", "", "`<anything>` — \(proseLine)"]
        for spec in all {
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

    /// What every outbound mail carries below the `-- ` marker.
    static var mailEntries: [(command: String, detail: String)] {
        all.filter { !$0.desktopOnly }.map { ($0.usage, $0.summary) }
    }

    /// What `setMyCommands` publishes, so typing `/` in a Telegram chat lists
    /// the verbs rather than requiring the user to have read `/help` once.
    ///
    /// Desktop-only verbs are left out: offering `/add` in a chat whose only
    /// possible answer is "there is no chat equivalent" is worse than an
    /// absence. Telegram caps a description at 256 characters, which every
    /// summary in this table is comfortably inside.
    static var botCommands: [(command: String, description: String)] {
        all.filter { !$0.desktopOnly }.map { ($0.verb, $0.summary) }
    }
}
