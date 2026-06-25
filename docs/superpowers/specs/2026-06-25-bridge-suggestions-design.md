# Bridge Suggestions (v1) — Design

**Date:** 2026-06-25
**Status:** Approved direction, v1 scoped

## Background & Motivation

Happy's mobile app shows tappable "suggestion buttons" after each agent message. It works because Happy renders its own chat UI: the agent emits an `<options>…</options>` XML block, Happy strips it from the displayed text and renders buttons instead. Tapping a button sends that option's text back as the next user message.

seahelm cannot copy this directly. seahelm displays a **live Ghostty terminal**, rendered by Ghostty's own Metal renderer straight from the PTY. seahelm only ever **reads** the terminal (`readViewportText()` for status polling) — it has no hook into rendering and cannot strip, filter, or hide anything the agent prints. Confirmed: there is no output-rewriting path anywhere in the codebase. Therefore any `<options>` XML the model prints into its message is permanently visible and ugly.

### Direction (decided)

A **hybrid** "intelligent observer" feeding the Bridge, where suggestions become clickable buttons:

- **B — agent self-report (this spec, v1):** the agent reports its own suggested next steps out-of-band so they never appear as raw XML in the terminal. Best relevance (the agent knows its own plan), free, instant, local.
- **C — LLM observer (future, v2):** seahelm watches raw terminal output and uses an LLM (gated by cheap heuristics) to surface anomalies the agent never reports — crashes, runaway exception logs, hung processes — as Bridge alerts. Out of scope for v1.

Both subsystems share the same downstream rail: **receive items → store on `AgentInfo` → render as buttons in the Bridge → click → `sendCommand` back to the agent.** v1 builds that rail with the cheap B path; v2's observer rides the same rail.

### The terminal-cleanliness tradeoff (decided)

It is **impossible** to have model-authored suggestions with zero terminal footprint, because Ghostty prints the model's message before any hook runs and seahelm cannot un-print it. The accepted compromise: the model does **not** print options as text. Instead it invokes a small command, which shows as **one clean tool-call line** (e.g. `⏺ Bash(seahelm-suggest …)`) rather than a raw XML block. That command POSTs the options to seahelm out-of-band.

## Goals (v1)

1. An agent can report 0–N suggested next-step strings without printing raw XML into the terminal.
2. seahelm receives those suggestions out-of-band and stores them per agent.
3. The Bridge renders the current agent's suggestions as clickable buttons; clicking sends the suggestion text to that agent and clears the list.
4. Suggestions auto-clear when the agent starts a new round (so stale suggestions never linger).
5. Works for both seahelm-launched and user-launched agents (Claude Code primary; Codex best-effort).

## Non-Goals (v1)

- The LLM observer / anomaly detection (entire C subsystem).
- A formal MCP tool (B2). v1 uses a shell command; the transport is isolated so MCP can replace it later without touching the rail.
- Pixel-perfect placement tuning of the suggestions area in the Bridge.
- Multi-agent broadcast of suggestions.

## Architecture

```
agent finishes a round, anticipates next steps
        │  runs:  seahelm-suggest "opt1" "opt2" "opt3"   (one clean tool-call line in terminal)
        ▼
seahelm-suggest script  ──HTTP POST──▶  WebhookServer (localhost:7070/webhook)
   { source, session_id, event:"suggest", cwd:<worktree>, options:[...] }
        ▼
WebhookEvent.parse → WebhookEventType.suggest
        ▼
WebhookStatusProvider.handleEvent → AgentHead.updateOptions(terminalID, options)
        ▼  (main-thread delegate: agentDidUpdate)
Bridge panel renders SuggestionChips for the active agent
        ▼  user clicks a chip
AgentHead.sendCommand(to: agentID, command: optionText)  +  clear that agent's options
```

A new agent round (`UserPromptSubmit` / status → busy / `agent_stop` of the *previous* round) clears `options` so they don't persist past relevance.

## Components

### 1. `seahelm-suggest` helper script

- A small shell script (zsh/bash, no runtime deps beyond `curl`) installed to a user bin dir at app launch.
- Distribution follows the existing `ClaudeStatuslineBridgeInstaller` precedent: on startup seahelm writes/updates the script to `~/.local/bin/seahelm-suggest` (creating the dir, `chmod +x`), and ensures that dir is reachable. The script is versioned with a header marker so seahelm can detect and overwrite stale copies.
- Behavior: takes each CLI arg as one option string; reads the webhook port (default 7070, overridable via `SEAHELM_WEBHOOK_PORT` env or `~/.config/seahelm/config.json`); POSTs JSON to `http://127.0.0.1:<port>/webhook`:
  ```json
  { "source": "seahelm-suggest", "session_id": "<unused-ok>", "event": "suggest",
    "cwd": "<$PWD>", "options": ["opt1", "opt2"] }
  ```
- `cwd` (the worktree path) is how seahelm maps the POST to an agent. The script uses `$PWD`.
- Exits 0 always (never blocks the agent). Failures are silent — a missing seahelm just means no buttons.

### 2. Webhook event: `suggest`

- Add `case suggest = "suggest"` to `WebhookEventType` (`Sources/Status/WebhookEvent.swift`).
- Carries `options: [String]` inside the existing `data: [String: Any]?` dict (key `"options"`). No struct change to `WebhookEvent` needed.
- `agentStatus(data:)` for `.suggest` returns the agent's current status unchanged (suggestions are informational, not a status transition). If the mapping requires a value, it must NOT force `.waiting`/`.idle`; prefer returning `nil`/no-op so existing status is preserved.

### 3. `AgentInfo.options` + `AgentHead.updateOptions`

- Add `var options: [String] = []` to `AgentInfo` (`Sources/Core/AgentInfo.swift`).
- Add `AgentHead.updateOptions(terminalID:options:)`: locks, diffs, updates, unlocks, then fires `delegate?.agentDidUpdate(info)` on the main queue — mirroring `updateStatus()`'s pattern exactly.
- Add clearing: when a new round begins for an agent, set `options = []`. Hook this into the existing status-transition path (e.g. when status leaves `idle/waiting` into `busy`, or on `userPrompt`/`sessionStart` webhook events for that worktree). Implemented as `AgentHead.clearOptions(terminalID:)` reused by both triggers.

### 4. Webhook routing

- In `WebhookStatusProvider.handleEvent` (`Sources/Status/WebhookStatusProvider.swift`): on `.suggest`, resolve the agent by `cwd` → worktree → terminalID (same resolution already used for other events), read `data["options"]` as `[String]`, call `AgentHead.shared.updateOptions(...)`.
- Reuse the existing worktree→agent lookup; do not add a parallel one.

### 5. Bridge UI: suggestion chips

- Render the **active agent's** `options` as a row/stack of clickable chips in `BridgePanelViewController`.
- Placement: a **new lightweight "Suggestions" area** distinct from Orders (red, approval-gated) and Watch (green, awareness). Rationale: suggestions are ephemeral quick-replies with different semantics, and v2's observer suggestions will land in the same area. Keep it minimal — a header + a wrapping chip stack; hidden when empty.
- Each chip: the option text (truncated with tooltip if long). Click → `onSuggestionPress(agentID, text)` callback to `MainWindowController` → `AgentHead.shared.sendCommand(to: agentID, command: text)` then `AgentHead.shared.clearOptions(terminalID: agentID)`.
- Refresh on `agentDidUpdate` for the active agent (same observer path the panel already uses).

### 6. Injection: telling agents about `seahelm-suggest`

- Extend `WorktreeCreator.createWorktree` (`Sources/Git/WorktreeCreator.swift`, after the worktree exists) to write/refresh a **managed block** in the worktree's `CLAUDE.md` (for Claude) and `AGENTS.md` (for Codex). The block is delimited by markers (e.g. `<!-- seahelm:suggest:start -->` … `<!-- seahelm:suggest:end -->`) so it can be idempotently updated and never duplicates or clobbers user content.
- Block content (concise): "When you finish a turn and can anticipate likely next steps the user might take, run `seahelm-suggest 'option one' 'option two'` (each option a short imperative phrase, max ~5). Do NOT print options as text in your reply. The user sees them as buttons."
- This covers **user-launched** agents too, because the agent reads `CLAUDE.md`/`AGENTS.md` on every launch regardless of who started it. Worktree-scoped (not global `~/.claude`) so it only affects sessions inside seahelm worktrees.
- Note: seahelm already auto-patches `~/.claude/settings.json` HTTP hooks at startup (`ClaudeHooksSetup`), so the webhook endpoint the script targets is already live; no additional hook config needed for v1.

## Data Flow Summary

1. Agent runs `seahelm-suggest "a" "b"` → terminal shows one tool-call line.
2. Script POSTs `{event:"suggest", cwd, options}` to `localhost:7070/webhook`.
3. `WebhookServer` → `WebhookEvent.parse` (`.suggest`) → `WebhookStatusProvider.handleEvent`.
4. Resolve agent by `cwd`; `AgentHead.updateOptions(terminalID, options)`.
5. `agentDidUpdate` (main thread) → Bridge re-renders suggestion chips for active agent.
6. User clicks chip → `sendCommand(to: agentID, command: text)` + `clearOptions`.
7. Next round begins → `clearOptions` ensures no stale buttons.

## Error Handling

- Script: silent best-effort; any curl/network failure exits 0, agent unaffected.
- Webhook: malformed/empty `options` → ignored (no update). Unknown `cwd` → no matching agent → drop.
- UI: empty `options` → suggestions area hidden. Clicking a chip whose agent disappeared → `sendCommand` no-ops on missing terminal (existing behavior).
- Idempotent injection: managed-block markers guarantee re-running `createWorktree` updates in place without duplicating.

## Testing

- **Pure/unit:**
  - `WebhookEvent.parse` correctly yields `.suggest` with `options` extracted from `data` (including empty/missing options → ignored).
  - `AgentHead.updateOptions` diffs correctly (no delegate fire when unchanged) and fires on change; `clearOptions` resets.
  - Managed-block writer: inserts when absent, updates in place when present, preserves surrounding user content, idempotent across runs.
- **Integration (manual smoke):**
  - Launch an agent in a worktree, run `seahelm-suggest "x" "y"` in its terminal → two chips appear in the Bridge.
  - Click a chip → the agent receives `x` as input; chips clear.
  - Start a new round → chips clear automatically.
  - Confirm only one clean tool-call line appears in the terminal (no raw `<options>` XML).

## Open Items for the Implementer

- Confirm the exact `cwd`→terminalID resolution helper already used in `WebhookStatusProvider` and reuse it (do not add a parallel lookup).
- Confirm the precise status-transition point to attach `clearOptions` (prefer an existing transition callback over a new poll).
- Decide the user bin dir for the script (`~/.local/bin` preferred) and ensure install runs at the same startup phase as `ClaudeHooksSetup` / `ClaudeStatuslineBridgeInstaller`.
- Choose `AgentType` detection for which file to inject (`CLAUDE.md` vs `AGENTS.md` vs both) at worktree creation; injecting both is acceptable since each agent only reads its own.

## Future (v2 — not in this spec)

LLM observer (C): gated by existing content-hash + status-transition signals, reads `readViewportText()`, calls an LLM to detect anomalies/suggest next steps for agents that don't self-report, emitting into the same Bridge rail (suggestions area for green, Watch/Orders for red alerts). Adds an LLM client + key management + trigger gating.
