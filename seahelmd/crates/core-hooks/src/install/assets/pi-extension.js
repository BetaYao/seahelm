// seahelm-pi-extension v2 — managed by seahelm. Do not edit; it is overwritten on launch.
//
// Reports Pi agent lifecycle to seahelm's control socket so a Pi pane shows
// precise running/idle status. Fire-and-forget: it never blocks or fails the
// agent, and silently no-ops when not launched inside a seahelm pane.
import { createConnection } from "node:net"

const HOME = process.env.HOME || ""
const SOCK = process.env.SEAHELM_SOCKET_PATH || `${HOME}/.config/seahelm/seahelm.sock`
// SEAHELM_PANE_ID is seahelm's stable pane id; SEAHELMD_SESSION carries the same
// value for panes created before that export existed.
const PANE = process.env.SEAHELM_PANE_ID || process.env.SEAHELMD_SESSION || ""

// `ctx` is Pi's per-event SessionManager handle. Its own session id/file are
// Pi's real resume handle (`pi --session <id>`) — PANE is only seahelm's pane
// name, not a Pi session Pi itself would recognize, so a resume built from it
// would silently fail to reattach the conversation.
function send(event, data, ctx) {
  if (!PANE) return
  let sessionId = PANE
  let sessionPath
  try {
    if (ctx && ctx.sessionManager) {
      sessionId = ctx.sessionManager.getSessionId?.() || PANE
      sessionPath = ctx.sessionManager.getSessionFile?.()
    }
  } catch {}
  let line
  try {
    line = JSON.stringify({
      id: "pi",
      method: "hook",
      params: {
        source: "pi",
        event,
        session_id: sessionId,
        session_path: sessionPath,
        seahelm_pane_id: PANE,
        cwd: process.cwd(),
        data: data || {},
      },
    }) + "\n"
  } catch {
    return
  }
  try {
    const sock = createConnection(SOCK)
    sock.on("error", () => {})            // socket absent / seahelm down — ignore
    sock.on("connect", () => sock.end(line))
    sock.setTimeout(2000, () => sock.destroy())
  } catch {}
}

export default function seahelm(pi) {
  // The agent started working on the user's message → running.
  pi.on("agent_start", (_e, ctx) => send("user_prompt", { message: "Working" }, ctx))
  // Tool calls keep the pane running and add activity detail.
  pi.on("tool_execution_start", (e, ctx) =>
    send("tool_use_start", { tool_name: (e && e.toolName) || "tool", tool_input: e && e.args }, ctx))
  pi.on("tool_execution_end", (e, ctx) =>
    send((e && e.isError) ? "tool_use_failed" : "tool_use_end", { tool_name: (e && e.toolName) || "tool" }, ctx))
  // Fully settled — no retry, compaction, or queued continuation → idle.
  pi.on("agent_settled", (_e, ctx) => send("agent_stop", {}, ctx))
}