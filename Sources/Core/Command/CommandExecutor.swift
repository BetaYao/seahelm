import Foundation

/// Where a line came from. Decides only what the surface *can do* — show a
/// sheet, open a panel — never what a command means.
struct CommandSurface: Equatable {
    /// `CommandSession` key: `desktop`, `telegram:<chat>`, `mail:<thread>`.
    let sessionKey: String
    /// The desktop has a selection to bind through and sheets to confirm with.
    let isDesktop: Bool
    /// Who is speaking, where the surface knows — a mail address, a Telegram id.
    let commander: String?

    static let desktop = CommandSurface(sessionKey: "desktop", isDesktop: true, commander: nil)

    init(sessionKey: String, isDesktop: Bool = false, commander: String? = nil) {
        self.sessionKey = sessionKey
        self.isDesktop = isDesktop
        self.commander = commander
    }
}

/// A button offered beside a reply.
///
/// The command language has no idea how a surface draws one: Telegram makes it
/// an inline keyboard, the desktop ignores it (its answer is the dashboard) and
/// mail drops it (a mail client cannot call back). What the layer below is told
/// is only what the button *means*.
struct CommandButton: Equatable {
    enum Effect: Equatable {
        /// Run this line, as if the tapper had typed it.
        case line(String)
        /// Withdraw the question this reply asked. Not a verb: any other
        /// message already withdraws a pending question, so the language never
        /// needed one — but a button has to name what it does.
        case cancelPending
    }

    let label: String
    let effect: Effect

    /// The common case: the button is the line it says.
    static func line(_ label: String, _ line: String) -> CommandButton {
        CommandButton(label: label, effect: .line(line))
    }
}

struct CommandReply: Equatable {
    let text: String
    let isError: Bool
    /// The desktop's listing is the dashboard; `/status` there navigates.
    let showsOverview: Bool
    /// The desktop drops reply text — the dashboard is its answer — except an
    /// outcome with something to act on: a PR link, a worktree held back.
    let presentsOnDesktop: Bool
    /// Offered beside the text on surfaces that can draw buttons. Always a
    /// shortcut for something the text already says how to type, so a surface
    /// that drops them loses nothing.
    let buttons: [CommandButton]

    init(_ text: String, isError: Bool = false, showsOverview: Bool = false,
         presentsOnDesktop: Bool = false, buttons: [CommandButton] = []) {
        self.text = text
        self.isError = isError
        self.showsOverview = showsOverview
        self.presentsOnDesktop = presentsOnDesktop
        self.buttons = buttons
    }

    /// Errors surface on the desktop too: a right-click Return that fails to
    /// parse or is refused used to only beep, which reads as "nothing happened".
    static func error(_ text: String) -> CommandReply {
        CommandReply(text, isError: true, presentsOnDesktop: true)
    }
}

/// The side effects a command can have. Implemented by the app layer; a test
/// implements it with a fake. Everything is called on the main thread.
protocol CommandHost: AnyObject {
    func fleetIndex() -> FleetIndex
    /// The desktop's own binding: the selected worktree's pane. Nil headless.
    var desktopBoundPaneKey: String? { get }
    var integrationEnabled: Bool { get }

    /// Path of the new worktree, or nil on failure.
    func createWorktree(task: String, repoPath: String, completion: @escaping (String?) -> Void)
    /// Desktop navigation: make this worktree current.
    func selectWorktree(path: String)
    func sendText(paneId: String, text: String) -> Bool
    func transcript(paneSessionKey: String) -> String?
    func activity(paneId: String) -> [String]
    /// Everything `/return` decides from, gathered off the main thread. The
    /// planner is pure, so this is the only place the verb touches git.
    func assessReturn(worktreePath: String, completion: @escaping (WorktreeReturnFacts) -> Void)
    /// Carry a plan out: commit, push and PR off the main thread, then the
    /// app's own worktree teardown when the plan reached its delete.
    func performReturn(_ plan: WorktreeReturnPlan, worktree: WorktreeRef,
                       completion: @escaping (WorktreeReturnOutcome) -> Void)
    /// The integration checkout is a worktree too; the sweep leaves it alone.
    func isIntegrationCheckout(worktreePath: String) -> Bool
    func forgetRepo(path: String)
    /// `heldByLocalEdits` is true when rerunning with `force` would clear the hold.
    func integrate(mode: IntegrationConflictMode, force: Bool,
                   completion: @escaping (_ summary: String, _ heldByLocalEdits: Bool) -> Void)
    /// Returns the stored text.
    func addIdea(text: String, source: String) -> String
    func openIssue(title: String)
    func addRepo()
    /// Desktop only: a native sheet. Chat surfaces never reach this.
    func confirm(_ summary: String, completion: @escaping (Bool) -> Void)
}

/// Runs one line for one surface. The only place a command's meaning lives,
/// which is what keeps the three surfaces from drifting.
final class CommandExecutor {
    private weak var host: CommandHost?
    let sessions: CommandSessionStore

    init(host: CommandHost, sessions: CommandSessionStore) {
        self.host = host
        self.sessions = sessions
    }

    /// Main thread. `reply` may fire more than once — an acknowledgement now
    /// and the outcome when async work lands — and the caller must accept both.
    func run(_ text: String, surface: CommandSurface, reply: @escaping (CommandReply) -> Void) {
        guard let host else { return }
        let index = host.fleetIndex()
        switch CommandParser.parse(text, index: index) {
        case .failure(let error):
            sessions.clearPending(for: surface.sessionKey)
            reply(.error(CommandFormatter.describe(error)))
        case .success(let line):
            if case .yes = line.command {
                confirmPending(surface: surface, reply: reply)
                return
            }
            // Anything but `/yes` withdraws the question.
            sessions.clearPending(for: surface.sessionKey)
            execute(line, index: index, surface: surface, reply: reply)
        }
    }

    // MARK: - Dispatch

    private func execute(_ line: ParsedLine, index: FleetIndex, surface: CommandSurface,
                         reply: @escaping (CommandReply) -> Void) {
        guard let host else { return }
        switch line.command {
        case .say(let text):
            say(text, index: index, surface: surface, reply: reply)

        case .new(let task, let repo):
            guard let repoPath = repo?.path ?? index.repos.first?.path else {
                reply(.error("No repo configured. Add one on the desktop."))
                return
            }
            let repoName = URL(fileURLWithPath: repoPath).lastPathComponent
            reply(CommandReply("Starting **\(repoName)** — \(task)"))
            host.createWorktree(task: task, repoPath: repoPath) { [weak self] path in
                guard let self, let host = self.host else { return }
                guard let path else {
                    reply(.error("Couldn't start a worktree in **\(repoName)**."))
                    return
                }
                // Starting work is also moving to it: a phone has no dashboard
                // to click, so a create that left the binding behind would
                // strand the next message.
                let fresh = host.fleetIndex()
                if let pane = fresh.panes(inWorktree: path).first {
                    self.bind(surface, to: pane)
                    reply(CommandReply("Started \(CommandFormatter.target(pane)). Talking to it from now on."))
                } else {
                    // The agent is still launching; bind to the place and let
                    // the first pane there pick the conversation up.
                    if surface.isDesktop {
                        host.selectWorktree(path: path)
                    } else {
                        self.sessions.bind(surface.sessionKey, toWorktreePath: path, commander: surface.commander)
                    }
                    let label = fresh.worktree(path: path).map { fresh.label(for: $0) } ?? path
                    reply(CommandReply("Started \(label). Talking to it as soon as its agent is up."))
                }
            }

        case .go(.pane(let pane)):
            bind(surface, to: pane)
            reply(CommandReply("Talking to \(CommandFormatter.target(pane)) — \(pane.status.icon) \(pane.status.groupLabel). Say anything to send it."))

        case .go(.worktree(let wt)):
            if let pane = index.panes(inWorktree: wt.path).first {
                bind(surface, to: pane)
                reply(CommandReply("Talking to \(CommandFormatter.target(pane)) — \(pane.status.icon) \(pane.status.groupLabel)."))
            } else {
                if surface.isDesktop {
                    host.selectWorktree(path: wt.path)
                } else {
                    sessions.bind(surface.sessionKey, toWorktreePath: wt.path, commander: surface.commander)
                }
                reply(CommandReply("Now on \(index.label(for: wt)) — no pane there yet. `/new <task>` to start one."))
            }

        case .show(let named):
            guard let pane = named ?? boundPane(surface, index: index) else {
                reply(.error(Self.notBoundHint))
                return
            }
            // On the desktop, looking at a pane is selecting it: there is no
            // other way to show one.
            if surface.isDesktop { host.selectWorktree(path: pane.worktreePath) }
            reply(CommandReply(CommandFormatter.paneDetail(
                pane,
                activity: host.activity(paneId: pane.id),
                transcript: pane.sessionKey.isEmpty ? nil : host.transcript(paneSessionKey: pane.sessionKey),
                footer: nil)))

        case .order(let pane, let text):
            reply(deliver(text, to: pane))

        case .broadcast(let text):
            let panes = index.panes.sorted { $0.handle < $1.handle }
            guard !panes.isEmpty else {
                reply(.error("No panes running."))
                return
            }
            let names = panes.map { "#\($0.handle)" }.joined(separator: " ")
            requireConfirmation("Send to \(panes.count) pane\(panes.count == 1 ? "" : "s"): \(names)?",
                                line: line, surface: surface, reply: reply) { [weak self] in
                guard let self, let host = self.host else { return }
                let live = host.fleetIndex().panes
                var sent = 0
                for pane in live where host.sendText(paneId: pane.id, text: text) { sent += 1 }
                reply(CommandReply("Sent to \(sent) pane\(sent == 1 ? "" : "s")."))
            }

        case .status(let scope):
            let bound = boundPane(surface, index: index)
            let text: String
            var buttons: [CommandButton] = []
            switch scope {
            case .panes:
                text = CommandFormatter.panes(index, bound: bound)
                buttons = CommandFormatter.paneButtons(index, bound: bound)
            case .worktrees:
                text = CommandFormatter.worktrees(index, bound: bound)
                buttons = CommandFormatter.worktreeButtons(index, bound: bound)
            case .repos:
                text = CommandFormatter.repos(index)
            }
            reply(CommandReply(text, showsOverview: surface.isDesktop, buttons: buttons))

        case .returnAll:
            // Only what nothing would be lost by goes without asking; the rest
            // is listed with what returning each would do, one `/return @x`
            // at a time — a sweep must not open five PRs on one stray line.
            let targets = index.worktrees.filter { !$0.isMain && !host.isIntegrationCheckout(worktreePath: $0.path) }
            guard !targets.isEmpty else {
                reply(CommandReply("Nothing to return — no linked worktrees."))
                return
            }
            sweep(targets, index: index, returned: [], remaining: [], reply: reply)

        case .returnWorktree(let wt):
            guard index.worktree(path: wt.path) != nil else {
                reply(.error(CommandFormatter.describe(.unknownWorktree(wt.branch))))
                return
            }
            let label = index.label(for: wt)
            host.assessReturn(worktreePath: wt.path) { [weak self] facts in
                guard let self, let host = self.host else { return }
                let plan = WorktreeReturnPlanner.plan(facts)
                switch plan {
                case .refuse(let why):
                    reply(.error("\(label) \(why)"))
                case .delete:
                    // Nothing would be lost, so nothing is asked — the same
                    // rule the row's Delete has always used.
                    host.performReturn(plan, worktree: wt) { outcome in
                        reply(CommandFormatter.returnOutcome(outcome, label: label))
                    }
                case .ship(let steps):
                    let summary = WorktreeReturnPlanner.summary(of: steps, label: label)
                    self.requireConfirmation(summary + "?", line: line, surface: surface, reply: reply) { [weak self] in
                        guard let self, let host = self.host else { return }
                        // Push and PR take seconds; say so before going quiet.
                        reply(CommandReply("Returning \(label)…"))
                        host.performReturn(plan, worktree: wt) { outcome in
                            reply(CommandFormatter.returnOutcome(outcome, label: label))
                        }
                    }
                }
            }

        case .forget(let repo):
            requireConfirmation("Drop **\(repo.name)** from seahelm? Its worktrees stay on disk; its sessions are killed.",
                                line: line, surface: surface, reply: reply) { [weak self] in
                self?.host?.forgetRepo(path: repo.path)
                reply(CommandReply("Dropped **\(repo.name)**. Its worktrees are still on disk."))
            }

        case .integrate(let mode):
            guard host.integrationEnabled else {
                reply(.error("Integration is turned off in Settings."))
                return
            }
            host.integrate(mode: mode, force: line.force) { [weak self] summary, held in
                guard let self else { return }
                // The one hold `force` clears. Ask, rather than making the
                // user retype the command with a word they have to know. On
                // the desktop the report card already carries that choice.
                guard held, !line.force, !surface.isDesktop else {
                    reply(CommandReply(summary))
                    return
                }
                self.requireConfirmation("\(summary)\nDiscard those edits and run again?",
                                         line: line, surface: surface, reply: reply) { [weak self] in
                    self?.host?.integrate(mode: mode, force: true) { summary, _ in
                        reply(CommandReply(summary))
                    }
                }
            }

        case .idea(let text):
            let stored = host.addIdea(text: text, source: surface.sessionKey)
            reply(CommandReply("Idea added: \(stored)"))

        case .feedback(let title):
            host.openIssue(title: title)
            reply(CommandReply("Opening GitHub issue for **seahelm**…"))

        case .help(let verb):
            if let verb {
                guard let text = CommandSpecs.help(for: verb) else {
                    reply(.error(CommandFormatter.describe(.unknownCommand(verb))))
                    return
                }
                reply(CommandReply(text))
            } else {
                reply(CommandReply(CommandSpecs.help))
            }

        case .yes:
            // Handled in `run`; a pending `/yes` line never gets here.
            reply(.error("Nothing to confirm."))

        case .add:
            if surface.isDesktop {
                host.addRepo()
                reply(CommandReply(""))
            } else {
                reply(.error("`/add` is desktop only — it needs a file picker."))
            }
        }
    }

    // MARK: - Sweep

    /// `/return` with no name: assess each linked worktree in turn, delete the
    /// ones with nothing to ship, and report the rest with their plans.
    private func sweep(_ pending: [WorktreeRef], index: FleetIndex,
                       returned: [String], remaining: [String],
                       reply: @escaping (CommandReply) -> Void) {
        guard let host else { return }
        guard let wt = pending.first else {
            reply(CommandReply(CommandFormatter.sweepReport(returned: returned, remaining: remaining),
                               presentsOnDesktop: !remaining.isEmpty))
            return
        }
        let rest = Array(pending.dropFirst())
        let label = index.label(for: wt)
        host.assessReturn(worktreePath: wt.path) { [weak self] facts in
            guard let self, let host = self.host else { return }
            let plan = WorktreeReturnPlanner.plan(facts)
            switch plan {
            case .refuse(let why):
                self.sweep(rest, index: index, returned: returned,
                           remaining: remaining + ["\(label) \(why)"], reply: reply)
            case .delete:
                host.performReturn(plan, worktree: wt) { [weak self] outcome in
                    let done = outcome.failure == nil ? returned + [label] : returned
                    let left = outcome.failure.map { remaining + ["\(label): \($0)"] } ?? remaining
                    self?.sweep(rest, index: index, returned: done, remaining: left, reply: reply)
                }
            case .ship(let steps):
                let line = WorktreeReturnPlanner.summary(of: steps, label: label) + " — `/return \(label)`"
                self.sweep(rest, index: index, returned: returned, remaining: remaining + [line], reply: reply)
            }
        }
    }

    // MARK: - Prose

    static let notBoundHint = "Not talking to any pane yet. `/status` to see them, then `/go #n` — or `/new <task>` to start one."

    private func say(_ text: String, index: FleetIndex, surface: CommandSurface,
                     reply: @escaping (CommandReply) -> Void) {
        if let pane = boundPane(surface, index: index) {
            reply(deliver(text, to: pane))
            return
        }
        // One pane is no choice at all; bind it and say so once.
        if !surface.isDesktop, index.panes.count == 1 {
            let pane = index.panes[0]
            bind(surface, to: pane)
            let sent = deliver(text, to: pane)
            reply(CommandReply("\(sent.text) — talking to it from now on.", isError: sent.isError))
            return
        }
        reply(.error(surface.isDesktop
                     ? "No pane selected. Pick one on the dashboard, or `/new <task>`."
                     : Self.notBoundHint))
    }

    private func deliver(_ text: String, to pane: PaneRef) -> CommandReply {
        guard let host else { return .error("Not running.") }
        if host.sendText(paneId: pane.id, text: text) {
            return CommandReply("→ \(CommandFormatter.target(pane))")
        }
        return .error("Couldn't reach \(CommandFormatter.target(pane)) — its terminal is gone. `/status` to see what's left.")
    }

    // MARK: - Binding

    /// The pane this surface is talking to. A binding that names a pane which
    /// has since closed falls back to the worktree it was in, then to nothing.
    func boundPane(_ surface: CommandSurface, index: FleetIndex) -> PaneRef? {
        if surface.isDesktop {
            guard let key = host?.desktopBoundPaneKey else { return nil }
            return index.pane(handleKey: key)
        }
        let session = sessions.session(for: surface.sessionKey)
        guard !session.closed else { return nil }
        if let key = session.boundPaneKey, let pane = index.pane(handleKey: key) { return pane }
        if let path = session.boundWorktreePath, let pane = index.panes(inWorktree: path).first {
            // A worktree binding resolves to its first pane and sticks to it.
            sessions.bind(surface.sessionKey, toPaneKey: pane.handleKey, paneId: pane.id, worktreePath: path)
            return pane
        }
        return nil
    }

    private func bind(_ surface: CommandSurface, to pane: PaneRef) {
        if surface.isDesktop {
            host?.selectWorktree(path: pane.worktreePath)
        } else {
            sessions.bind(surface.sessionKey, toPaneKey: pane.handleKey, paneId: pane.id,
                          worktreePath: pane.worktreePath, commander: surface.commander)
        }
    }

    // MARK: - Confirmation

    /// One question, asked the way the surface can: a sheet on the desktop,
    /// a pending `/yes` in chat, or not at all when the line said `force`.
    private func requireConfirmation(_ summary: String, line: ParsedLine, surface: CommandSurface,
                                     reply: @escaping (CommandReply) -> Void,
                                     then proceed: @escaping () -> Void) {
        if line.force {
            proceed()
            return
        }
        if surface.isDesktop {
            host?.confirm(summary) { ok in if ok { proceed() } }
            return
        }
        sessions.setPending(PendingAction(line: ParsedLine(line.command, force: true),
                                          summary: summary,
                                          expiresAt: Date().addingTimeInterval(PendingAction.lifetime)),
                            for: surface.sessionKey)
        reply(CommandReply("\(summary)\nReply `/yes` within \(Int(PendingAction.lifetime))s to go ahead.",
                           buttons: [.line("Go ahead", "/yes"),
                                     CommandButton(label: "Cancel", effect: .cancelPending)]))
    }

    private func confirmPending(surface: CommandSurface, reply: @escaping (CommandReply) -> Void) {
        guard let host else { return }
        guard let pending = sessions.takePending(for: surface.sessionKey) else {
            reply(.error("Nothing to confirm."))
            return
        }
        // Re-parsed against the live fleet through the stored line, so a pane
        // that closed in between is caught rather than acted on blindly.
        execute(pending.line, index: host.fleetIndex(), surface: surface, reply: reply)
    }
}
