# New Task → Auto-Launch Agent + Auto-Summarized Title

**Date:** 2026-06-11
**Status:** Design — pending implementation plan

## Problem

When the user creates a new task, amux creates a git worktree but the selected
agent (Claude, Codex, …) never actually starts. The user expects: create the
worktree, **launch the agent immediately so it starts working in the
background**, and have the mini-card / capsule title be an auto-summarized
description of the task (the way Claude/Codex summarize a session) instead of
the raw branch name.

### Why it's broken today

The launch path exists but is timing-based and races against lazy UI rendering,
so it never fires reliably:

- `MainWindowController.launchAgent(_:inWorktree:taskDescription:)`
  (`Sources/App/MainWindowController.swift:575`) waits 1.5s, finds the surface,
  types `claude\r` via `surface.sendText`, then waits another 2s and types the
  task description.
- But a `TerminalSurface`'s Ghostty PTY / backend session is created **lazily**
  — only when the card is first focused (`embedSplitContainerForSelectedAgent`).
  In Grid layout it may never be created until clicked. So `sendText` at 1.5s
  hits a surface with no PTY, and the keystrokes vanish.

### Key architectural fact this design exploits

zmx/tmux sessions are **persistent and server-side**, named by
`SessionManager.persistentSessionName(for: worktreePath)`
(`Sources/Core/SessionManager.swift:11`). The GUI surface merely *attaches* to a
session (`zmx attach <name>` / `tmux new-session|attach`) inside
`TerminalSurface.create()` (`Sources/Terminal/TerminalSurface.swift:43`). The
session's existence does **not** depend on the GUI.

Therefore we can pre-create the session **detached, with the agent already
running**, at task-creation time. The surface lifecycle needs **no changes** —
when the user later opens the card, the existing `attach` path connects to the
already-running agent.

## Goals

1. Creating an AI-agent task launches that agent in its worktree **immediately
   and in the background**, independent of whether/when the card is opened.
   Creating N tasks runs N agents in parallel.
2. The task description is reliably delivered to the agent as its first prompt.
3. The card/capsule title shows a meaningful summary from creation onward, and
   upgrades to the agent's own AI-generated summary when available.

## Non-Goals

- Codex-specific session-title reader (a `CodexTitleLookup` analogous to
  `SessionTitleLookup`). Codex tasks will show the user's task description until
  this is added as a follow-up.
- Changing surface lifecycle, split layout, or reparenting behavior.
- Auto-launching non-AI "shell tasks" (npm, btop, …). Those keep today's lazy
  plain-shell behavior.

## Part A — Reliable background launch

### A1. Per-agent launch command with task — `AgentType`

Add to `Sources/Core/AgentType.swift`:

```swift
/// Full agent invocation including the task as the agent's initial prompt.
/// Returns nil for non-AI / shell types (no auto-launch).
func launchCommand(withTask task: String) -> String?
```

Both `claude` and `codex` accept the prompt as a positional argument and start
an interactive session (`claude [options] [prompt]`, `codex [OPTIONS]
[PROMPT]`). This is the stablest injection — **no send-keys timing race**.

- AI agents with a `launchCommand`: return `"<launchCommand> <shell-escaped
  task>"` when `task` is non-empty, else just `launchCommand`.
- The task MUST be shell-escaped (single-quote wrap with `'\''` handling) since
  it becomes part of a shell command string.
- Non-AI types: return nil (caller skips pre-launch).

> Note: the positional-prompt form is verified for the installed `claude` and
> `codex` binaries. Any future agent whose CLI lacks a positional prompt falls
> back to launch-only (agent starts, task not auto-sent) — acceptable
> degradation; a send-keys fallback can be added later if needed.

### A2. Detached session creation — `SessionManager`

Add to `Sources/Core/SessionManager.swift` (it already owns session naming,
killing, resizing):

```swift
/// Create a persistent backend session detached, running `command` in `cwd`,
/// only if a session named `name` does not already exist. Runs Process calls;
/// call off the main thread. Returns whether a new session was launched.
@discardableResult
static func createDetachedSession(
    name: String, backend: String, cwd: String, command: String
) -> Bool
```

Behavior:

- **Idempotency:** if the session already exists, do nothing and return false.
  (tmux: `tmux has-session -t <name>`; zmx: parse `zmx list`.) This prevents
  double-launching on relaunch/session-restore.
- **Command wrapping for PATH + shell parity:** run the agent under a
  login-interactive shell so the user's PATH resolves the agent binary, and keep
  a shell alive after the agent exits (matching today's "type `claude` into a
  shell" UX where you return to a prompt when the agent quits):

  ```
  $SHELL -lic '<agent-cmd>; exec $SHELL -l'
  ```

- **tmux:** `tmux new-session -d -s <name> -c <cwd> <wrapped>`
- **zmx:** create detached running `<wrapped>` in `<cwd>`.
  > **Verification step during implementation:** confirm zmx's exact CLI for
  > "create detached + run a command in a working dir". If zmx cannot
  > create-detached-with-command, fall back to: create the detached session,
  > then push the command into it via zmx's send/run equivalent. Either way it
  > stays fully server-side (no GUI dependency).

When the GUI later attaches via `TerminalSurface.create()`, the existing
`has-session`→attach (tmux) / `zmx attach` path connects to this live session.
No surface code changes.

### A3. Wire-up — `MainWindowController` create closure

In the inline-create `onCreate` closure
(`Sources/App/MainWindowController.swift:411-433`), after
`WorktreeCreator.createWorktree` and `WorktreeAgentTypeStore.shared.set(...)`:

- Persist the task (Part B1): `WorktreeTaskStore.shared.set(taskDescription,
  forWorktree: info.path)`.
- If `agentType.launchCommand(withTask: taskDescription) != nil`, call
  `SessionManager.createDetachedSession(...)` on the existing background queue
  (the closure already runs on `DispatchQueue.global`), with
  `name = persistentSessionName(for: info.path)`, `backend = config.backend`,
  `cwd = info.path`.
- **Remove** `launchAgent(_:inWorktree:taskDescription:)` and its call site
  entirely (the fragile timer path).

Errors (agent binary missing, session create failure) are non-fatal: the
worktree still exists; the user sees the error in the terminal when they open
the card.

## Part B — Auto-summarized title

### B1. Persist the task description — `WorktreeTaskStore`

New `Sources/Core/WorktreeTaskStore.swift`, mirroring
`WorktreeAgentTypeStore` (`~/.config/amux/worktree-tasks.json`,
`[worktreePath: String]`), with `shared`, `task(forWorktree:)`,
`set(_:forWorktree:)`.

### B2. Insert task tier into title resolution — `WorktreeTitleResolver`

Current priority (`Sources/Core/WorktreeTitleResolver.swift`): Claude summary →
lastUserPrompt → branch.

New priority:

**Claude session summary → stored task description → lastUserPrompt → branch**

- Claude's AI-generated summary stays highest (best title once it exists).
- The stored task description gives an immediate, meaningful title from creation
  and for agents/states where no summary exists yet.
- Add a `taskDescription` lookup closure param defaulting to
  `WorktreeTaskStore.shared.task(forWorktree:)`, injectable for tests (same
  pattern as the existing `sessionTitle` param).

`WorktreeTitleCache` (`Sources/Core/WorktreeTitleCache.swift`) needs no
signature change — the resolver reads the store by path internally. Its 8s TTL
means the title upgrades to Claude's summary within ~8s of the summary appearing.

## Data flow (after change)

```
Create task (inline form: task, repo, agentType)
  └─ background queue:
       WorktreeCreator.createWorktree
       WorktreeAgentTypeStore.set(agentType, path)
       WorktreeTaskStore.set(task, path)                 # Part B1
       SessionManager.createDetachedSession(             # Part A2
           name=persistentSessionName(path),
           backend, cwd=path,
           command="$SHELL -lic 'claude \"<task>\"; exec $SHELL -l'")
  └─ main queue:
       tabCoordinator.handleNewBranch(info, repoPath)    # unchanged
       dashboard.selectAgent(byWorktreePath: path)

Agent now running server-side in the session, regardless of GUI focus.

Open the card (any time later):
  TerminalSurface.create → zmx attach / tmux attach  →  agent already working

Title (capsule + mini card), via WorktreeTitleCache → WorktreeTitleResolver:
  Claude summary → task description → lastUserPrompt → branch   # Part B2
```

## Files touched

| File | Change |
|------|--------|
| `Sources/Core/AgentType.swift` | add `launchCommand(withTask:)` + shell-escape helper |
| `Sources/Core/SessionManager.swift` | add `createDetachedSession(name:backend:cwd:command:)` + existence check |
| `Sources/Core/WorktreeTaskStore.swift` | **new** — persist task per worktree |
| `Sources/Core/WorktreeTitleResolver.swift` | add task-description tier |
| `Sources/App/MainWindowController.swift` | wire pre-launch + task store into create closure; remove `launchAgent` |

## Testing

- `AgentType.launchCommand(withTask:)`: AI agents compose `"claude '<task>'"`
  with correct escaping; empty task → bare command; non-AI → nil; special chars
  (quotes, `$`, spaces) escaped safely.
- `WorktreeTaskStore`: round-trip set/get; missing path → nil; persists JSON.
- `WorktreeTitleResolver`: each priority tier wins in order (summary > task >
  prompt > branch); empty/whitespace task is skipped.
- `SessionManager.createDetachedSession`: idempotency (existing session → no
  relaunch, returns false). Command construction asserted via a seam (inject the
  process runner / capture the argv) rather than spawning real sessions.

## Risks / open items

- **zmx detached-create-with-command CLI** — primary verification item (A2).
  tmux is well-understood; zmx fallback is create-detached + send.
- **Shell escaping** of the task is security/robustness critical (it enters a
  shell command string). Use a single, tested escaping helper.
- **PATH in detached session** — relying on `$SHELL -lic` to source the user's
  profile; verify the agent binary resolves in the spawned session.
