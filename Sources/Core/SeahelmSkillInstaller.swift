import Foundation

/// Installs the agent skill at ~/.claude/skills/seahelm/SKILL.md so Claude Code
/// agents running inside a seahelm pane auto-discover how to drive the
/// multiplexer via the `seahelm` CLI. The first rule is the SEAHELM_ENV guard:
/// an agent must not touch the CLI unless it is actually inside a seahelm pane.
enum SeahelmSkillInstaller {
    private static let versionMarker = "<!-- seahelm-skill v6 -->"

    static func skillContents() -> String {
        return """
        ---
        name: seahelm
        description: >-
          Drive the seahelm terminal multiplexer from inside a pane — spawn
          sibling panes, run commands, read their output, and wait on a pane's
          agent status. Use when coordinating work across panes, running a task
          in a side pane, or spawning a helper/sub-agent.
        ---
        \(versionMarker)

        # seahelm

        You may be running inside **seahelm**, a terminal multiplexer. The
        `seahelm` CLI lets you drive it: open panes, run commands, read output,
        and wait on state.

        ## Guard — check this FIRST

        Only use `seahelm` commands if the environment variable `SEAHELM_ENV` is
        `1`. If it is not set, you are **not** inside a seahelm-managed pane —
        do not run `seahelm` commands (they would target another user's session
        or fail). Quick check:

        ```sh
        [ "$SEAHELM_ENV" = 1 ] || { echo "not inside seahelm"; }
        ```

        Your own pane is `$SEAHELM_PANE_ID`. Pass it (or another pane id) to the
        commands below; omit the id to target the currently focused pane.

        ## Concepts

        - **pane** — one terminal running a shell, agent, or command. Referenced
          by `$SEAHELM_PANE_ID` (yours) or an id from `seahelm pane list`.
        - **status** — `idle | running | waiting | error | exited`. For waits,
          `done` means finished (idle or exited).

        ## Commands

        ```sh
        seahelm session snapshot                 # JSON: every pane + status
        seahelm pane list                        # JSON: same
        seahelm pane read <pane> [--source visible|recent|detection] [--lines N]
        seahelm pane run <pane> <command...>     # type command + Enter
        seahelm pane send-text <pane> <text...>  # type without Enter
        seahelm pane send-keys <pane> <key...>   # keys: enter esc tab up down left right ctrl+c ...
        seahelm pane split [<pane>] [--direction right|left|down|up] [--no-focus]
                                                 # prints the NEW pane id
        seahelm pane focus <pane>                # give it keyboard focus
        seahelm pane close <pane>                # close it (kills its session)
        seahelm pane explain <pane>              # JSON: why this pane is in its status (matched rule + evidence)
        seahelm pane zoom [<pane>] [--on|--off]  # tmux-style full-tab zoom (toggles by default)
        seahelm wait output <pane> --match TEXT [--regex] [--source recent] [--timeout MS]
                                                 # exit 0 if seen, 1 on timeout
        seahelm wait agent-status <pane> --status done [--timeout MS]
                                                 # exit 0 when status reached, 1 on timeout
        seahelm events [--pane P] [--type pane.status_changed] [--after SEQ]
                                                 # stream pane events as JSON lines (until killed)
        seahelm layout export                    # JSON: capture the current split layout as a template
        seahelm layout apply <file|->            # rebuild splits from a template (stdin with -)
        ```

        Output contract: `run`/`send-*` print nothing; `read` prints raw text;
        `list`/`snapshot`/`split` print (split prints just the new id); `wait`
        commands signal via exit code (0 = matched, 1 = timed out).

        ## Recipes

        Run a task in a side pane without stealing your cursor, then read it:

        ```sh
        NEW=$(seahelm pane split --no-focus)
        seahelm pane run "$NEW" npm run dev
        seahelm wait output "$NEW" --match "ready" --timeout 60000
        seahelm pane read "$NEW" --lines 40
        ```

        Spawn a second agent and wait for it to finish:

        ```sh
        HELP=$(seahelm pane split --no-focus)
        seahelm pane run "$HELP" claude
        seahelm wait output "$HELP" --match ">" --timeout 30000
        seahelm pane run "$HELP" "review the diff in src/api and list risks"
        seahelm wait agent-status "$HELP" --status done --timeout 600000
        seahelm pane read "$HELP" --lines 80
        ```

        Interrupt a stuck pane:

        ```sh
        seahelm pane send-keys "$PANE" escape
        seahelm pane send-keys "$PANE" ctrl+c
        ```

        ## Notes

        - Pane ids from `pane list`/`snapshot` (`pane_id`) are per-session; your
          own stable id is `$SEAHELM_PANE_ID` (shown as `session_name` in the
          snapshot). Either form works as a `<pane>` argument.
        - Re-read ids after closing panes; don't cache a `pane_id` across changes.
        """
    }

    @discardableResult
    static func ensureInstalled() -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/seahelm", isDirectory: true)
        return ensureInstalled(directory: dir)
    }

    @discardableResult
    static func ensureInstalled(directory: URL) -> Bool {
        let fileURL = directory.appendingPathComponent("SKILL.md")
        let desired = skillContents()
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8),
           existing.contains(versionMarker), existing == desired {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try desired.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("[SeahelmSkillInstaller] Failed to install: \(error)")
            return false
        }
    }
}
