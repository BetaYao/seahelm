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
    /// Resolution order (per-pane, never worktree-scoped, so sibling agent panes
    /// stay distinct):
    /// 1. Agent session title (per-session id) — *strong*, persisted
    /// 2. OSC title (agent panes, live) — *strong*, persisted
    /// 3. `Station.persistedTitle` — last strong title, so a restored pane shows
    ///    its real title before a fresh OSC/session arrives after relaunch
    /// 4. Shell command line (non-agent panes only)
    /// 5. Branch name (the worktree default)
    /// 6. Repo name, else the worktree path
    ///
    /// Steps 1–2 write the resolved title back to `Station.persistedTitle` so it
    /// survives a relaunch (saved into the split layout).
    static func title(
        for pane: PaneInfo,
        sessionTitle: (String, String) -> String? = { path, sid in
            SessionTitleLookup.title(worktreePath: path, sessionId: sid)
                ?? CursorSessionTitleLookup.title(worktreePath: path, sessionId: sid)
        },
        pathDisplay: (String) -> String = { shortenPath($0) }
    ) -> String {
        singleLine(resolvedTitle(for: pane, sessionTitle: sessionTitle, pathDisplay: pathDisplay))
    }

    /// Flatten to one line. Several sources are free-form user text — a Claude
    /// session title is the first user prompt, which is routinely a multi-line
    /// block — and every surface that shows a title gives it a single row.
    /// Trimming alone left the embedded newlines, so one prompt-shaped title
    /// grew a dashboard row to full-card height.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func resolvedTitle(
        for pane: PaneInfo,
        sessionTitle: (String, String) -> String?,
        pathDisplay: (String) -> String
    ) -> String {
        // A pane whose OSC title is the shell prompt (`user@host:/path`) is sitting
        // at a shell right now — even if its agent type is stale (an agent that
        // exited back to a shell keeps `claudeCode`/`codex`). Treat it as a shell
        // so its command line wins instead of the agent session/OSC title.
        let atShellPrompt = isShellPromptTitle(pane.station?.oscTitle, worktreePath: pane.worktreePath)
        let treatAsAgent = isAgentPane(pane) && !atShellPrompt

        // 1. Per-session agent title — two agents in one tree must not share it.
        if treatAsAgent, let ref = pane.station?.agentSessionRef, ref.kind == .id,
           let title = sessionTitle(pane.worktreePath, ref.sessionId)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            pane.station?.persistedTitle = title
            pane.station?.titleBridgeActive = false
            return title
        }

        // 2. The terminal's own OSC title — the only per-pane source that updates
        // live, so it wins for agent panes. (Shell-prompt titles are already
        // rejected by displayOscTitle, so this never yields a bare path.)
        if treatAsAgent, let osc = oscTitle(for: pane) {
            pane.station?.persistedTitle = osc
            pane.station?.titleBridgeActive = false
            return osc
        }

        // 3. Shell command line — for real shell panes and for agent panes that
        // have dropped back to a shell prompt. Guarded off for live agents so a
        // cursor-agent tool `cd` can't steal the title.
        if !treatAsAgent,
           let cmd = pane.commandLine?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cmd.isEmpty {
            pane.station?.titleBridgeActive = false
            return cmd
        }

        // 4. Last-known strong title, restored from the saved layout. Bridges the
        // startup gap where OSC/session data hasn't landed yet — without it every
        // restored pane collapsed to the same branch/repo fallback.
        //
        // Only while `titleBridgeActive`: the flag is set at layout-restore and
        // cleared the instant any live source above resolves, so the persisted
        // title bridges *this* pane's restore gap but never leaks into a later
        // session started in the same pane (after `/clear` or an agent restart),
        // where the stale title would duplicate the sibling pane's. Also skipped
        // at a live shell prompt — proof the agent has exited back to a shell.
        if pane.station?.titleBridgeActive == true, !atShellPrompt,
           let persisted = pane.station?.persistedTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines), !persisted.isEmpty {
            return persisted
        }

        // 5. Branch (the worktree default).
        let branch = pane.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty { return branch }

        // 6. Repo name, else the worktree path.
        let project = pane.project.trimmingCharacters(in: .whitespacesAndNewlines)
        if !project.isEmpty { return project }
        return pathDisplay(displayPath(for: pane))
    }

    /// The pane whose title represents the whole worktree: the current (focused)
    /// pane when it maps to a live pane, otherwise the most-recently-active
    /// pane (by `activityEvents`, then `startedAt`). `fallback` is returned only
    /// when the worktree has no panes at all.
    static func representativePane(
        focusedStationId: String?,
        among panes: [PaneInfo],
        fallback: PaneInfo
    ) -> PaneInfo {
        if let focusedStationId,
           let focused = panes.first(where: { $0.id == focusedStationId }) {
            return focused
        }
        return panes.max(by: { lastActivity($0) < lastActivity($1) }) ?? fallback
    }

    private static func lastActivity(_ pane: PaneInfo) -> Date {
        pane.activityEvents.map(\.timestamp).max() ?? pane.startedAt ?? .distantPast
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
    /// `Station` (no AgentRegistry round-trip — its snapshots trail the poll cycle).
    static func displayOscTitle(_ raw: String?, worktreePath: String, pwd: String = "") -> String? {
        guard let raw else { return nil }
        let stripped = raw.drop { ch in
            ch.isWhitespace || !(ch.isLetter || ch.isNumber || ch.isPunctuation)
        }
        let title = String(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        // Shells and some agents park the cwd in the title — the path fallback
        // below already handles that, and handles it better. Reject the bare
        // path, the shell prompt form (`user@host:/path`), and the plain
        // directory name: macOS zsh titles a window with just the basename, and
        // agents that set no title of their own (Codex) inherit it.
        guard !isDirectoryTitle(title, of: worktreePath),
              !isDirectoryTitle(title, of: pwd),
              !isShellPromptTitle(title, worktreePath: worktreePath) else { return nil }
        return title
    }

    /// True when `title` is just `path` — spelled out, `~`-shortened, or reduced
    /// to its last component.
    private static func isDirectoryTitle(_ title: String, of path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return title == path
            || title == shortenPath(path)
            || title == (path as NSString).lastPathComponent
    }

    /// True when an OSC title is really a shell prompt — `user@host:/path` — for
    /// this worktree (the title contains the worktree path or its `~` form). Such
    /// a title is the shell announcing its cwd, never a meaningful pane title.
    static func isShellPromptTitle(_ raw: String?, worktreePath: String) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              !worktreePath.isEmpty else { return false }
        return raw.contains(worktreePath) || raw.contains(shortenPath(worktreePath))
    }

    private static func oscTitle(for pane: PaneInfo) -> String? {
        displayOscTitle(pane.station?.oscTitle, worktreePath: pane.worktreePath,
                        pwd: pane.station?.pwd ?? "")
    }

    /// Per-pane only — a worktree-scoped agent pick must not make shell siblings
    /// skip `commandLine` (they'd fall through to branch).
    private static func isAgentPane(_ pane: PaneInfo) -> Bool {
        if pane.agentType.isAIAgent { return true }
        if pane.station?.agentSessionRef != nil { return true }
        return false
    }

    /// Prefer the worktree root over a tool-use cwd that wandered outside it
    /// (e.g. `~/.cursor/plugins/cache/...` during Cursor skill reads).
    private static func displayPath(for pane: PaneInfo) -> String {
        let root = pane.worktreePath
        if let station = pane.station {
            let pwd = station.pwd.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pwd.isEmpty, pwd == root || pwd.hasPrefix(root + "/") {
                return pwd
            }
        }
        return root
    }
}
