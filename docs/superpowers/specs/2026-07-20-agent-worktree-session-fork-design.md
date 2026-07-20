# Agent Worktree Session Fork Design

**Date:** 2026-07-20

**Status:** Approved direction

**Scope:** When an agent running in one Seahelm pane creates a Git worktree, keep the original pane/session and start a forked agent session in the new worktree.

## 1. Decision

Seahelm will not try to change the current working directory of an already-running third-party agent process, reparent the process as if it had started elsewhere, or clone it with the Unix `fork()` syscall.

Instead, Seahelm treats relocation as a session-level operation:

1. Keep the source pane, process, and native agent session unchanged.
2. Identify the exact source pane, agent type, native session reference, repository, and target worktree.
3. Create a new Seahelm pane/session rooted at the target worktree.
4. Ask the agent CLI to fork the native conversation when it supports that operation.
5. If the CLI cannot fork safely, do not silently resume the same native session in two processes. Offer an explicit fallback instead.

This makes the result a branch of the conversation as well as a branch of the code. It is reversible and preserves the main worktree as the foreground context.

## 2. Terminology

- **Pane:** Seahelm's visible terminal unit, identified by `SEAHELM_PANE_ID` and backed by a `Station`.
- **Backend session:** The zmx session that keeps a pane's process alive.
- **Native agent session:** Claude/Codex/Cursor/OpenCode's stored conversation, identified by the agent's own session ID.
- **Source:** The pane and worktree in which worktree creation was requested.
- **Target:** The newly created Git worktree.
- **Session fork:** A new native agent session initialized from the source conversation, with an independent session ID.
- **Resume-only:** Reopening the same native session ID. Resume-only is not safe while the source process remains active.

Changing a `SplitTree.worktreePath` changes Seahelm bookkeeping only. It does not change any running process's cwd, sandbox root, loaded instructions, environment, or native conversation identity.

## 3. Goals

1. A precisely attributed worktree creation can automatically start a forked agent in that worktree.
2. The source pane remains alive and associated with its original worktree.
3. Only the pane that initiated creation participates; sibling split panes remain untouched.
4. The target process starts with the target as its real cwd so it reloads repository instructions, project configuration, sandbox boundaries, MCP configuration, and environment.
5. A failed fork leaves the source untouched and the new worktree usable.
6. Ambiguous attribution never causes an automatic fork.
7. Agent-specific CLI details are isolated behind adapters and capability checks.

## 4. Non-goals

- Moving or cloning an arbitrary running OS process.
- Moving the whole source `SplitTree` to the target.
- Automatically closing the source agent.
- Running the same non-forked native session concurrently in two processes.
- Inferring ownership solely from a worktree directory name.
- Making Cursor behave as if it had native session fork support.
- Replacing Git worktree creation for every agent in the first version.

## 5. Capability Matrix

Capabilities must be detected from the installed CLI rather than assumed from the agent name. Version parsing may be used as a fast path, but `--help`/feature probing is authoritative because distributions can differ.

| Agent | Fork command | Target cwd | Automatic policy |
|---|---|---|---|
| Codex | `codex fork <session-id>` | `-C <target>` | Supported when session ID and `fork` capability are present |
| Claude Code | `claude --resume <session-id> --fork-session` | Launch process with target as cwd | Supported when `--fork-session` is present |
| OpenCode | `opencode <target> --session <session-id> --fork` | Project path argument or target cwd | Supported when session ID and `--fork` are present |
| Cursor Agent | No documented native fork | Launch process with target as cwd | Never automatic; offer fresh-session handoff or exclusive resume |

References:

- [Codex CLI command reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli) documents stable `codex fork` and `--cd`/`-C`.
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-usage) documents `--fork-session` with `--resume`/`--continue`.
- [OpenCode CLI reference](https://opencode.ai/docs/cli/) documents `--session` plus `--fork` and a project path.
- [Cursor CLI parameters](https://docs.cursor.com/en/cli/reference/parameters) document resume but no conversation fork.

The command builders return argv arrays, never interpolated shell strings. Existing permission/model/profile flags should be preserved only when Seahelm can obtain them safely; otherwise the target process loads its normal target-directory configuration.

## 6. Architecture

### 6.1 `AgentRuntimeIdentity`

The current `AgentSessionRef` is necessary but not sufficient because it is effectively persisted by a worktree-derived primary session name. Forking requires per-pane identity.

```swift
struct AgentRuntimeIdentity: Codable, Equatable {
    let paneID: String
    let agent: String
    let nativeSession: AgentSessionRef
    let observedCwd: String
    let repositoryIdentity: String
    let observedAt: Date
}
```

The authoritative key is `paneID`. `worktreePath` is mutable routing data and cannot identify a process. Session hook/plugin events carrying a pane ID update this record. A session reference discovered without a pane ID may update status but is not eligible for automatic fork.

`repositoryIdentity` is derived from the canonical Git common directory, not the directory basename. This distinguishes same-named worktrees in different repositories.

### 6.2 `WorktreeForkIntent`

```swift
struct WorktreeForkIntent {
    let id: UUID
    let sourcePaneID: String
    let sourceWorktreePath: String
    let repositoryIdentity: String
    let nativeSession: AgentSessionRef
    let requestedTargetPath: String?
    let requestedName: String?
    let createdAt: Date
    var state: State
}
```

The intent state machine is:

```text
recorded -> targetResolved -> launching -> ready
    |              |             |
    +-----------> failed <-------+
    +-----------> expired
```

An intent is consumed only by an exact target path or by an unambiguous match within the same repository. A basename match is insufficient. Intents remain inspectable after failure for diagnostics but cannot be launched twice.

### 6.3 `AgentSessionForkAdapter`

```swift
enum ForkCapability {
    case nativeFork
    case resumeOnly
    case unavailable(reason: String)
}

protocol AgentSessionForkAdapter {
    func capability(executable: String) -> ForkCapability
    func forkArgv(session: AgentSessionRef, targetPath: String) throws -> [String]
    func readinessSignal(for session: AgentSessionRef) -> ReadinessSignal
}
```

There are separate adapters for Claude, Codex, OpenCode, and Cursor. Cursor returns `.resumeOnly`; its adapter must not generate an automatic launch command while the source is active.

### 6.4 `WorktreeSessionForkCoordinator`

The coordinator owns intent correlation and the two-phase launch. It depends on small interfaces rather than directly manipulating dashboard state:

- runtime identity store;
- Git worktree discovery/repository identity resolver;
- agent adapter registry;
- detached zmx session launcher;
- station/tree registrar;
- readiness observer;
- user-visible event/order sink.

It does not call the existing `transferTree(fromPath:toPath:)` path. The target receives a new tree or pane. The source tree remains registered exactly as it was.

## 7. Intent Sources and Attribution

Automatic forking requires all of the following:

1. Exact `sourcePaneID`.
2. A valid, current native session reference for that pane.
3. A repository identity shared by source and target.
4. An exact target path, or a single newly discovered target matching a recorded intent.
5. A native fork capability from the installed agent CLI.

Intent producers, in reliability order:

1. **Seahelm-created worktree:** the UI/control API knows the source pane and returned target path. This is fully automatic.
2. **Explicit agent control call:** an agent creates or selects a worktree and calls a future `seahelm worktree fork --path <absolute-path>` command. `SEAHELM_PANE_ID` supplies exact attribution. This is the portable route for all agents.
3. **Native hook/plugin event:** accepted only if it reports source pane/session and a resolvable target. Claude/Codex hooks and the OpenCode plugin can provide session identity; each integration must be verified against its actual event schema.
4. **Uncorrelated Git discovery:** Seahelm shows “Fork current agent here” on the new worktree item. It does not auto-select the most recently active pane.

Parsing arbitrary shell text such as `git worktree add ...` is only a hint for UI presentation. Shell grammar, aliases, scripts, and agent tool wrappers make it unsuitable as an authority for process creation.

### Claude `WorktreeCreate` constraint

Claude Code's `WorktreeCreate` hook replaces its default worktree creation behavior; it is not a passive notification hook. A hook must synchronously return the created absolute path. Therefore Seahelm must not install a reporting-only `WorktreeCreate` hook.

The implementation must choose one of these explicit behaviors:

- remove Seahelm's global `WorktreeCreate` hook and rely on the explicit Seahelm control route/native post-creation discovery; or
- intentionally become the worktree creator and return the required path, with separate product semantics for Claude-native isolation.

The first behavior is the v1 choice. It is smaller, does not hijack Claude's native lifecycle, and matches the cross-agent design.

## 8. Launch Sequence

```text
source agent creates/selects target worktree
             |
             v
record intent with pane + native session + repo identity
             |
             v
Git discovery resolves and validates exact target path
             |
             v
probe installed agent fork capability
             |
             v
reserve target zmx session and create target Station
             |
             v
launch native fork with real cwd = target path
             |
             v
wait for process/session readiness
       | success                 | timeout/exit
       v                         v
register target pane       destroy only target attempt
publish ready event        keep worktree + source unchanged
focus target optionally    publish retry/manual action
```

The target UI item may exist before its agent is ready. It displays a launching state rather than borrowing the source station.

The new agent receives an initial continuation prompt only if needed, for example: “Continue the task in this worktree. The source conversation remains active in the original checkout.” The prompt must not claim that files were moved; Git is the source of truth.

## 9. Readiness and Atomicity

Creating a zmx session is not sufficient proof that the native fork succeeded. Readiness requires:

- the backend session exists;
- the agent process has not exited;
- and either a matching session-start hook/plugin event arrives for the target pane or a conservative agent-specific TUI readiness pattern is observed.

Hook/plugin confirmation is preferred. Screen recognition is a fallback and must be time-bounded.

Until readiness:

- the source remains focused and writable;
- the target is marked `launching`;
- no source registrations/layouts are removed;
- no pending intent is considered complete.

On timeout or early process exit, Seahelm tears down only the attempted target station/backend session. It preserves the worktree itself because it may contain user-created state.

## 10. Cursor Fallback

Cursor's documented CLI can resume a chat but does not expose a native fork. Seahelm must not start `cursor-agent --resume <id>` in the target while the source is running.

The target worktree offers two explicit actions:

1. **Start fresh with handoff:** launch a new Cursor chat with a concise prompt containing the task description, source branch/worktree, and last known user request. This is lossy and labeled as such.
2. **Move session here:** stop the source Cursor process after confirmation, then resume the same chat in the target. This is migration, not fork, and is outside automatic v1 behavior.

If Cursor later adds a documented fork flag/API, capability probing can promote it to native fork without changing coordinator semantics.

## 11. OpenCode Integration

Seahelm already installs an OpenCode plugin. Extend that plugin to report session ID, project directory, and pane ID on suitable session lifecycle events. The plugin should only report identity; the coordinator remains responsible for launch decisions.

OpenCode also exposes a server endpoint for session fork. The CLI route is preferred in v1 because Seahelm currently owns terminal processes and zmx sessions. A future server-backed adapter may call the API and attach a TUI, but it must preserve the same capability/readiness contract.

## 12. UI Behavior

When a correlated worktree appears:

- add the worktree item immediately;
- show `Forking Codex…`, `Forking Claude…`, or `Forking OpenCode…` while launching;
- on success, show an independent agent/pane under the new item;
- do not navigate automatically if the user has changed focus since the intent was recorded;
- otherwise optionally focus the new worktree according to a preference.

For ambiguous or unsupported cases, show a compact action:

- `Fork current agent here` when the user can select an eligible source pane;
- `Start fresh with handoff` for Cursor;
- `Retry fork` after a launch failure;
- a precise reason when the session ID or CLI capability is missing.

## 13. Persistence and Recovery

Persist runtime identity by pane/backend session name, not by worktree-derived primary name. Persist only validated native session references.

Persist non-terminal fork intents while launching so an app restart can reconcile them:

- if the target backend session exists and reports the expected target cwd, adopt it;
- if the target worktree exists but no process exists, mark the intent failed and offer retry;
- never relaunch automatically from a stale intent after its TTL;
- never modify the source during recovery.

The orphan zmx reaper must consider target sessions referenced by launching intents active until the intent reaches a terminal state.

## 14. Security and Validation

- Treat session IDs and paths as data, not shell fragments.
- Reuse `AgentSessionRef` validation and construct argv arrays.
- Canonicalize source/target paths and verify both belong to the same Git common directory.
- Reject missing targets, symlink escapes that resolve outside the discovered worktree, and targets already owned by a conflicting live pane.
- Never inherit a broader sandbox/approval policy merely to make the fork succeed.
- Do not send transcript content to a different agent provider as a fallback.

## 15. Changes to Existing Behavior

The current transfer prototype should be retired from this flow:

- `PendingTransferTracker` must stop matching by last path component alone.
- `performPaneTransfer` must not be called for session fork intents.
- `paneId` becomes required for automatic behavior and must actually select one source pane.
- `recordAgentSession` must store identity for the emitting pane instead of deriving only the primary session name from `worktreePath`.
- the reporting-only Claude `WorktreeCreate` hook must be removed for v1.

The existing tree-transfer primitive may remain for a distinct manual UI operation, but it must not be described as agent/session relocation.

## 16. Testing

### Unit tests

- Capability/argv tests for every adapter, including unsupported versions.
- Intent matching by canonical target path and Git common directory.
- Same-name cross-repository worktrees never match.
- Missing pane ID or native session ID never auto-forks.
- Only the initiating split pane is selected.
- State-machine idempotency, expiry, retry, and duplicate discovery.
- Cursor never emits a concurrent resume command.
- All argv values remain separate and session/path validation is enforced.

### Coordinator integration tests

- Codex/Claude/OpenCode success: source remains registered, target gets a new station, readiness completes the intent.
- Child exits before readiness: only target attempt is removed.
- App restart during launch reconciles without duplicating a process.
- Worktree deletion during launch fails cleanly.
- Orphan cleanup does not reap a reserved launching session.

### UI tests

- Worktree item moves from discovered to launching to ready.
- Unsupported/ambiguous cases show the correct action.
- User focus is not stolen after they navigate elsewhere.
- Retry does not duplicate panes.

### Manual compatibility matrix

Run an end-to-end scenario with installed versions of Claude Code, Codex CLI, Cursor Agent, and OpenCode. Record the probed capability, session ID source, exact argv, readiness signal, and observed target cwd.

## 17. Delivery Order

1. Correct identity storage to be per pane and remove unsafe basename correlation.
2. Introduce capability adapters and pure argv tests.
3. Add the fork coordinator and two-phase zmx launch without automatic triggers.
4. Wire Seahelm-created worktrees and the explicit control command.
5. Add Claude/Codex/OpenCode identity producers and safe automatic correlation.
6. Add UI launching/failure/fallback states.
7. Remove the reporting-only Claude `WorktreeCreate` hook.
8. Run the four-agent compatibility matrix before enabling automatic fork by default.

Automatic fork should initially ship behind a preference/feature flag. Native-fork adapters can graduate independently; Cursor remains fallback-only until its CLI exposes a real fork operation.
