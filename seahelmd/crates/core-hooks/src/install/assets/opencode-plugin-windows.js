// seahelm-suggest-plugin v4 — managed by seahelm. Do not edit; it is overwritten on launch.
//
// Windows build: everything goes through the seahelm-hook binary (there is
// no `nc` and no POSIX suggest script here), which tags the payload and
// writes it to seahelm's named pipe.
//
// Registers a `seahelm_suggest` tool that reports next-step options to
// seahelm's control socket, where they render as clickable buttons, and
// mirrors opencode's native `question` tool into a seahelm question card.
// Also reports session lifecycle (real opencode `sessionID`, not just
// seahelm's pane id) so seahelm can resume this exact opencode session
// (`opencode resume <id>`) if its seahelmd session is ever lost and recreated.
//
// The @opencode-ai/plugin import needs no setup: opencode writes its own
// ~/.config/opencode/package.json pinning the package to its version and
// installs it on startup. `tool()` is an identity function and
// `tool.schema` is a zod re-export, so this costs only the resolve.
import { tool } from "@opencode-ai/plugin"

const HOOK = __SEAHELM_HOOK__
// Same fallback chain as seahelm-hook: panes created before
// SEAHELM_PANE_ID was exported still carry SEAHELMD_SESSION.
const PANE = process.env.SEAHELM_PANE_ID ?? process.env.SEAHELMD_SESSION ?? ""

export const SeahelmSuggest = async ({ $, directory }) => {
  // Sessions opencode has told us are subagents (Task-tool children), via
  // their `parentID` on session.created. `session.idle` carries only a bare
  // sessionID, so this is the one place we can catch them before they'd
  // otherwise read as the main pane's agent going idle.
  const subagentSessions = new Set()

  // Each session's working directory, learned from the Session payload
  // opencode attaches to session.created / session.updated (`info.directory`
  // — opencode's own model is `{cwd: directory, root: worktree}`).
  //
  // The plugin's `directory` argument is bound once when the plugin loads,
  // so reporting it would peg every event to wherever the process started —
  // and a worktree in opencode *is* a session pointed at another directory.
  // seahelm decides which worktree card a pane belongs to from this cwd, so
  // a stale one keeps the pane filed under the worktree it left.
  const dirBySession = new Map()

  // Send a webhook-shaped payload over the control socket's `hook` method.
  // Mimics Claude's event shape so the existing HookDecoder path applies.
  // `sessionId` is opencode's own session id when known (the real resume
  // handle); PANE is only seahelm's pane name and never means anything to
  // `opencode resume`, so it's strictly a fallback for status bookkeeping.
  const send = async (event, data, sessionId, source = "opencode") => {
    if (!PANE) return
    const payload = JSON.stringify({
      source,
      event,
      session_id: sessionId || PANE,
      seahelm_pane_id: PANE,
      cwd: (sessionId && dirBySession.get(sessionId)) || directory || "",
      data,
    })
    // seahelm-hook reads the payload on stdin and wraps it in the `hook` call.
    await $`${HOOK} opencode < ${new Response(payload)}`.quiet().nothrow()
  }

  return {
    // Session lifecycle, independent of whether the question tool ever
    // fires — the only reliable place to learn opencode's real sessionID.
    event: async ({ event }) => {
      // Record the directory before the guard below: it is carried by the
      // Session payload, not by the bare `sessionID` the other branches key
      // off, and session.updated (which is otherwise ignored here) is how a
      // session that moved reports its new one.
      const info = event.properties?.info
      if (info?.id && typeof info.directory === "string" && info.directory) {
        dirBySession.set(info.id, info.directory)
      }
      const id = event.properties?.sessionID ?? info?.id
      if (!id) return
      if (event.type === "session.created") {
        if (event.properties?.info?.parentID) {
          subagentSessions.add(id)
          return
        }
        await send("session_start", {}, id)
      } else if (event.type === "session.idle") {
        if (subagentSessions.has(id)) return
        await send("agent_stop", {}, id)
      }
    },
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
      }, input.sessionID)
    },
    // The dialog is gone once the tool returns (answered in the TUI or via
    // a card tap) — a tool_use_end lets seahelm clear a stale card.
    "tool.execute.after": async (input) => {
      if (input.tool !== "question") return
      await send("tool_use_end", { tool_name: "AskUserQuestion" }, input.sessionID)
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
          await send("suggest", { options }, undefined, "seahelm-suggest")
          return `Reported ${options.length} suggestion(s) to seahelm.`
        },
      }),
    },
  }
}