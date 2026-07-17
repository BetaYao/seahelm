import Foundation

/// Installs an opencode plugin that registers a native `seahelm_suggest` tool,
/// so opencode panes can report next-step options the way Claude and Codex do.
///
/// Why a tool and not a hook: opencode's plugin API has no Claude-shaped Stop
/// hook. Its `session.idle` event does fire at turn end, but the `event` hook's
/// return value is not consumed, so `StopHookResponder.blockBody`'s reverse
/// trigger — a `{"decision":"block"}` on stdout that pushes the agent to call
/// seahelm-suggest — has no counterpart here. The only interceptive hook is
/// `tool.execute.before` (throw to veto one tool call), which is the wrong
/// shape. So the model calls a tool directly; `SuggestGuidanceWriter`'s
/// AGENTS.md block is what tells it to.
///
/// The plugin shells out to the seahelm-suggest script rather than opening the
/// socket itself: `SeahelmSuggestInstaller` rewrites that script on every launch
/// and owns the pane-id fallback and JSON escaping. A second copy here would be
/// a second thing to keep in sync.
enum OpenCodePluginInstaller {
    // Ownership marker (no version): the overwrite guard checks `contains`, so a
    // versioned marker would make every older install look foreign and freeze it.
    private static let versionMarker = "// seahelm-suggest-plugin"

    /// Note `plugins/`, plural. opencode's own docs say `plugin/`, but the
    /// loader reads `plugins/` — a file in the singular directory is silently
    /// ignored, with no error to notice.
    static func pluginContents() -> String {
        return """
        \(versionMarker) v2 — managed by seahelm. Do not edit; it is overwritten on launch.
        //
        // Registers a `seahelm_suggest` tool that reports next-step options to
        // seahelm's control socket, where they render as clickable buttons, and
        // mirrors opencode's native `question` tool into a seahelm question card.
        //
        // The @opencode-ai/plugin import needs no setup: opencode writes its own
        // ~/.config/opencode/package.json pinning the package to its version and
        // installs it on startup. `tool()` is an identity function and
        // `tool.schema` is a zod re-export, so this costs only the resolve.
        import { tool } from "@opencode-ai/plugin"

        const SCRIPT = `${process.env.HOME}/.local/bin/seahelm-suggest`
        const SOCK = process.env.SEAHELM_SOCKET_PATH ?? `${process.env.HOME}/.config/seahelm/seahelm.sock`
        // Same fallback chain as the suggest script: panes created before
        // SEAHELM_PANE_ID was exported still carry ZMX_SESSION.
        const PANE = process.env.SEAHELM_PANE_ID ?? process.env.ZMX_SESSION ?? ""

        export const SeahelmSuggest = async ({ $, directory }) => {
          // Send a webhook-shaped payload over the control socket's `hook` method.
          // Mimics Claude's event shape so the existing HookDecoder path applies.
          const send = async (event, data) => {
            if (!PANE) return
            const req = JSON.stringify({
              id: "opencode-question",
              method: "hook",
              params: {
                source: "opencode",
                event,
                session_id: PANE,
                seahelm_pane_id: PANE,
                cwd: directory ?? "",
                data,
              },
            })
            await $`printf '%s\\n' ${req} | nc -U ${SOCK}`.quiet().nothrow()
          }

          return {
            // opencode's native question tool blocks the agent on a choice, like
            // Claude's AskUserQuestion. Forward it as that event so seahelm shows
            // the same tappable card. Multi-select questions are skipped entirely:
            // a card tap sends one Down×n+Enter, which would only toggle an option,
            // and forwarding a subset would desync followup indices from the TUI.
            "tool.execute.before": async (input, output) => {
              if (input.tool !== "question") return
              const questions = output.args?.questions ?? []
              if (questions.length === 0 || questions.some((q) => q.multiple)) return
              await send("tool_use_start", {
                tool_name: "AskUserQuestion",
                tool_input: { questions },
              })
            },
            // The dialog is gone once the tool returns (answered in the TUI or via
            // a card tap) — a tool_use_end lets seahelm clear a stale card.
            "tool.execute.after": async (input) => {
              if (input.tool !== "question") return
              await send("tool_use_end", { tool_name: "AskUserQuestion" })
            },
            tool: {
              seahelm_suggest: tool({
                description:
                  "Report 2-5 short imperative next-step options to the user. They " +
                  "appear as clickable buttons in seahelm, so do not also print them " +
                  "as text. Call this at the end of a turn, before yielding to the user.",
                args: {
                  options: tool.schema
                    .array(tool.schema.string())
                    .describe("2-5 short imperative next steps, e.g. 'Run the tests'"),
                },
                async execute(args) {
                  const options = (args.options ?? []).filter((o) => o && o.trim())
                  if (options.length === 0) return "No options given; nothing reported."
                  // Bun's $ expands an array into separate argv entries, so the
                  // script's own escaping sees each option whole.
                  await $`${SCRIPT} ${options}`.quiet().nothrow()
                  return `Reported ${options.length} suggestion(s) to seahelm.`
                },
              }),
            },
          }
        }
        """
    }

    /// opencode resolves its config dir from XDG_CONFIG_HOME, falling back to
    /// ~/.config. Mirror it, or we install where a customized opencode never looks.
    static func pluginsDirectory() -> URL {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("opencode/plugins", isDirectory: true)
    }

    @discardableResult
    static func ensureInstalled() -> Bool {
        ensureInstalled(pluginsDirectory: pluginsDirectory())
    }

    @discardableResult
    static func ensureInstalled(pluginsDirectory directory: URL) -> Bool {
        let fileURL = directory.appendingPathComponent("seahelm-suggest.js")
        let desired = pluginContents()

        if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
            if existing == desired { return false }
            // Users drop their own plugins in here (and symlink them). Anything
            // without our marker is someone else's file that happens to share the
            // name; overwriting it would delete their work.
            guard existing.contains(versionMarker) else {
                NSLog("[OpenCodePluginInstaller] seahelm-suggest.js exists but is not ours; leaving it alone")
                return false
            }
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try desired.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("[OpenCodePluginInstaller] Failed to install: \(error)")
            return false
        }
    }
}
