# Bridge Command Input Design

**Date:** 2026-06-24
**Status:** Approved (design discussion locked)

## Problem

The bottom-of-column task input (`InlineWorktreeCreateView`) has a single intent:
always "create a worktree + launch an agent" via `onCreate(task, repo, agent, reuseEnv)`.
We want it to be a **First Mate command entry**: besides creating a worktree, the
Captain should be able to issue other orders — dispatch to an existing worktree,
return a worktree to port (delete), broadcast to the whole fleet — from one box.

Plus a small layout request on the Bridge panel: the Orders / Watch vertical split
should be roughly even (currently Orders dominates).

## Decisions (locked)

1. **Interaction form: hybrid / command palette.** No prefix = create worktree
   (preserve current muscle memory). Typing `/` triggers a command palette with
   completion. New First Mate actions are registered, not laid out as new chips.

2. **Execution pipeline: unified entry, zone-based control.** The text box does
   not execute directly for every command. Instead it produces a parsed command,
   and routing follows the same green/red principle as the First Mate engine:
   - **Green / high-frequency / reversible** → execute directly (current feel).
   - **Red / irreversible or high-blast-radius** → construct a `FirstMateAction`
     and enqueue into `PendingOrdersQueue`, so it appears in the Bridge pending
     list **isomorphic** with auto-suggested orders and reuses the existing
     two-step confirm UI.

3. **`/broadcast` is RED.** Reversible (just sends text) but high blast radius
   (hits the whole fleet at once) → enqueue for confirmation showing "will
   broadcast to N agents".

4. **`<wt>` argument resolves by branch name**, completed from the same worktree
   list source as the Cmd+P quick switcher. Users pick a branch, never type a path.

5. **No-prefix default = create new worktree** (`/order` is the explicit form for
   dispatching to an existing worktree). Preserves current behavior.

## Command Set

| Input | Meaning | Zone | Route |
|---|---|---|---|
| `<free text>` (no prefix) | create worktree + launch agent | green | direct (`onCreate`) |
| `/new <task>` | same, explicit | green | direct |
| `/order <branch> <task>` | append a command to an existing worktree's agent | green | direct → `AgentHead.sendCommand` |
| `/commit <branch>` | run the inspect/auto-commit chain manually | green | direct |
| `/return <branch>` | return to port: delete worktree | **red** | enqueue → Bridge two-step confirm (reuse `ReturnToPort` precheck) |
| `/broadcast <task>` | send a command to every active agent | **red** | enqueue → confirm "broadcast to N agents" |

## Architecture

```
command palette input
  → BridgeCommandParser.parse(text, worktrees) → BridgeCommand   [pure, testable, mirrors FirstMate.evaluate]
      ├─ green command → call injected execution closure directly (create wt / sendCommand / commit)
      └─ red command   → build FirstMateAction(+payload) → PendingOrdersQueue.enqueue
                          → Bridge pending list (same shape as auto-suggested orders)
                          → handleBridgeApprove executes on confirm
```

`BridgeCommandParser` is a pure function in the spirit of `FirstMate.evaluate`:
no IO, no singletons, fully unit-testable. Side effects live in closures injected
at the coordinator layer (`MainWindowController`).

### Data model changes

- `FirstMateActionKind` gains `.broadcastOrder` (red). `.returnToPort` already exists.
- `FirstMateAction` gains `payload: String?` to carry the task text for
  `/broadcast` (and any future order that needs free text). `worktreePath`/`branch`
  already cover `/return`.
- `handleBridgeApprove` learns to execute `.returnToPort` (delete via existing
  worktree-deletion path with `ReturnToPort` precheck warnings) and `.broadcastOrder`
  (iterate active agents → `sendCommand`).

## Layout: Orders / Watch even split

In `BridgePanelViewController`, the Orders and Watch scroll views currently use
unrelated `greaterThanOrEqual` minHeights, so Orders dominates. Add an explicit
proportional constraint: `watchScroll.height == ordersScroll.height` (1.0, pure
even split). Keep minHeights as floors only.

## Out of scope

- Command history / up-arrow recall.
- Fuzzy command matching beyond simple prefix + branch completion.
- Persisting palette state across relaunch.
