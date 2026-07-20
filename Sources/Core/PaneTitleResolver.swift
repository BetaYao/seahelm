import Foundation

/// Resolves the human-facing title for one split pane (not the whole worktree).
///
/// Order:
/// 1. Per-session title (Claude JSONL / Cursor `meta.json`) when `agentSessionRef` is set
/// 2. Worktree-scoped session title (Claude, then Cursor) — agent panes only
/// 3. Last user prompt
/// 4. Shell: last command line (non-AI only)
/// 5. Branch
/// 6. Worktree path (never a wandering tool cwd outside the worktree)
enum PaneTitleResolver {
    static func title(
        for sailor: SailorInfo,
        sessionTitle: (String, String) -> String? = { path, sid in
            SessionTitleLookup.title(worktreePath: path, sessionId: sid)
                ?? CursorSessionTitleLookup.title(worktreePath: path, sessionId: sid)
        },
        worktreeSessionTitle: (String) -> String? = { path in
            SessionTitleLookup.title(worktreePath: path)
                ?? CursorSessionTitleLookup.title(worktreePath: path)
        },
        pathDisplay: (String) -> String = { shortenPath($0) }
    ) -> String {
        // The terminal's own OSC title is the only per-pane source that updates
        // live. Everything below it is either worktree-scoped (identical for
        // sibling agent panes, so switching panes appeared to do nothing) or
        // only refreshed when the agent next writes — hence a title that moved
        // on message, not on click.
        if isAgentPane(sailor), let osc = oscTitle(for: sailor) {
            return osc
        }

        // Per-session next — two agents in one tree must not share a title.
        if let ref = sailor.station?.agentSessionRef, ref.kind == .id,
           let title = sessionTitle(sailor.worktreePath, ref.sessionId)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }

        // Worktree-scoped session title only for agent panes. A shell sibling
        // must not inherit the agent session name (e.g. "Seahelm Layout Redesign").
        if isAgentPane(sailor),
           let title = worktreeSessionTitle(sailor.worktreePath)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }

        let prompt = sailor.lastUserPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { return prompt }

        // Shell command only when this pane isn't an AI agent — otherwise a
        // cursor-agent tool `cd` would steal the row title.
        if !isAgentPane(sailor),
           let cmd = sailor.commandLine?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cmd.isEmpty {
            return cmd
        }

        let branch = sailor.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty { return branch }

        return pathDisplay(displayPath(for: sailor))
    }

    /// Last-selected leaf in the tree, else the first leaf, else `nil`.
    static func focusedStationId(in tree: SplitTree?) -> String? {
        guard let tree else { return nil }
        if let focused = tree.allLeaves.first(where: { $0.id == tree.focusedId }) {
            return focused.stationId
        }
        return tree.allLeaves.first?.stationId
    }

    static func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Private

    /// The pane's OSC title, stripped of the agent's leading spinner frame
    /// (`✳`, `⠐`, `⠂`, …). The glyph changes every animation tick, so keeping it
    /// would rewrite the header continuously. Nil when nothing usable is left,
    /// or when the title is just the pane's directory.
    ///
    /// Public because the click→title fast path resolves straight from a
    /// `Station` (no ShipLog round-trip — its snapshots trail the poll cycle).
    static func displayOscTitle(_ raw: String?, worktreePath: String) -> String? {
        guard let raw else { return nil }
        let stripped = raw.drop { ch in
            ch.isWhitespace || !(ch.isLetter || ch.isNumber || ch.isPunctuation)
        }
        let title = String(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        // Shells and some agents park the cwd in the title — the path fallback
        // below already handles that, and handles it better.
        guard title != worktreePath, title != shortenPath(worktreePath) else { return nil }
        return title
    }

    private static func oscTitle(for sailor: SailorInfo) -> String? {
        displayOscTitle(sailor.station?.oscTitle, worktreePath: sailor.worktreePath)
    }

    /// Per-pane only — a worktree-scoped agent pick must not make shell siblings
    /// skip `commandLine` (they'd fall through to branch).
    private static func isAgentPane(_ sailor: SailorInfo) -> Bool {
        if sailor.agentType.isAIAgent { return true }
        if sailor.station?.agentSessionRef != nil { return true }
        return false
    }

    /// Prefer the worktree root over a tool-use cwd that wandered outside it
    /// (e.g. `~/.cursor/plugins/cache/...` during Cursor skill reads).
    private static func displayPath(for sailor: SailorInfo) -> String {
        let root = sailor.worktreePath
        if let station = sailor.station {
            let pwd = station.pwd.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pwd.isEmpty, pwd == root || pwd.hasPrefix(root + "/") {
                return pwd
            }
        }
        return root
    }
}
