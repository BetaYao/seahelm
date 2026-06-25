# Keyboard Navigation Design

**Date:** 2026-04-11
**Status:** Draft — pending user review

## Goal

Let users operate amux's three highest-frequency workflows entirely from the keyboard, without touching the mouse:

1. Switching between dashboard layouts (Grid / Left-Right / Top-Small / Top-Large) and focusing a specific worktree within a layout.
2. Creating a new worktree through the new-branch dialog.
3. Deleting a worktree from the dashboard.

Full keyboard coverage of every UI surface is a non-goal. The design intentionally stays focused on these three flows.

## Guiding Principles

- **Native idiom first.** Tab for focus cycling is the standard macOS habit; we reuse it rather than inventing a new vocabulary.
- **Explicit, bounded modality.** When the UI needs to steal keys from the terminal, it happens through one explicit shortcut (`Cmd+E`) and returns to terminal input automatically once the action completes or is cancelled.
- **No hidden branches.** At any moment the user can answer the question "what will Tab do right now?" by knowing which of three states they are in.
- **Reuse existing coordinators.** Worktree creation, deletion, and layout switching already have code paths; this design only adds keyboard entry points, it does not reimplement the underlying operations.

## Non-Goals

- Making every button and control in the title bar, notification panel, or AI panel keyboard-navigable.
- Introducing a command palette, leader key, or vim-style global modal.
- Changing or replacing any existing keyboard shortcut.
- Settings-window keyboard support (out of scope for this spec).

## Core Concept: Three-State Focus Model

At any time the amux window is in exactly one of these states:

| State | First responder | Tab behavior | Entry |
|---|---|---|---|
| **T — Terminal Focus** | `GhosttyNSView` (a terminal surface) | Forwards `\t` to the PTY | Default when in a focus layout, or when user hits `Return` / `Esc` in **D** |
| **D — Dashboard Navigation** | Dashboard container view | Cycles focus across cards and the big panel | Automatic when entering **Grid** layout; `Cmd+E` from **T** in focus layouts |
| **M — Modal Dialog** | Dialog's initial first responder | Dialog-local | Opening a dialog (e.g. `Cmd+N`, `Cmd+P`) |

Rules:

- Entering **Grid** layout transitions `T → D` automatically.
- Entering a focus layout (Left-Right / Top-Small / Top-Large) transitions `D → T` automatically, restoring first responder to the focus panel's active split leaf.
- `Cmd+E` in a focus layout transitions `T → D`.
- In **D**, `Return` confirms the current focus (see §3.2) and transitions back to **T**.
- In **D**, `Esc` or `Cmd+E` cancels and transitions back to **T**, restoring the first responder that was active before entering **D** (snapshot-based).

## 1. Key Bindings

### Global (any state)

| Key | Action | State change |
|---|---|---|
| `Cmd+1` | Switch to Grid layout | → **D** (auto) |
| `Cmd+2` | Switch to Left-Right | → **T** |
| `Cmd+3` | Switch to Top-Small | → **T** |
| `Cmd+4` | Switch to Top-Large | → **T** |
| `Cmd+N` | New worktree dialog (existing) | → **M** |
| `Cmd+P` | Quick Switcher (existing) | → **M** |
| `Cmd+0` | Dashboard tab (existing) | Auto by layout |
| `Cmd+}` / `Cmd+{` | Next / previous project tab (existing) | unchanged |
| `Cmd+B` | Toggle sidebar collapse (existing) | unchanged |

### T state only

All existing split-pane shortcuts remain unchanged: `Cmd+D`, `Cmd+Shift+D`, `Cmd+Option+Arrow`, `Cmd+Ctrl+Arrow`, `Cmd+W`, etc.

Plus:

| Key | Action |
|---|---|
| `Cmd+E` | Enter **D** state (UI navigation mode). In **Grid** this is a no-op since the user is already in **D**. |

### D state only

| Key | Action |
|---|---|
| `Tab` | Move focus to next target in the Tab ring |
| `Shift+Tab` | Move focus to previous target |
| `Return` | Confirm current focus (see §3.2) and return to **T** |
| `Esc` | Cancel, return to **T** with previous first responder restored |
| `Cmd+E` | Same as `Esc` |
| `Cmd+Backspace` or `Delete` | Delete the currently focused mini card's worktree (routes through existing `TerminalCoordinator` / `DialogPresenter` confirmation flow) |

### M state

Each dialog defines its own key handling. See §4 for the new-branch dialog.

## 2. Grid Mode Behavior

### 2.1 Tab ring

In Grid layout, Tab cycles through cards in their rendered order:

```
[card 0] → [card 1] → [card 2] → … → [card N-1] → [card 0] …
```

Shift+Tab cycles in reverse.

### 2.2 Initial focus

When entering Grid (via `Cmd+1`, layout change from another mode, or coming back from a focus layout), the initial focus lands on the card corresponding to the **most recently used worktree** — typically the worktree that was the focus panel's main before switching to Grid. If no such worktree can be identified (e.g. first launch), focus lands on the first card.

### 2.3 Return semantics

Pressing `Return` while a card is focused in Grid mode:

1. Switches layout to the **last-used focus layout** (defaults to Left-Right if no prior focus layout is recorded in this session).
2. Promotes the focused card's worktree to the focus panel's main.
3. Transitions to **T**, with first responder on the new main worktree's active split leaf.

### 2.4 Delete

Pressing `Cmd+Backspace` or `Delete` while a card is focused in Grid mode invokes the existing delete-worktree flow via `TerminalCoordinator` (which presents the existing confirmation dialog through `DialogPresenter`). On confirm, the card is removed from the grid and focus moves to the next card in the ring (or the previous one if the deleted card was last).

### 2.5 Visual feedback

- Focused card: 2px brand-cyan border + subtle outer glow.
- No global "mode" banner in Grid (Grid is inherently a browsing state).
- Terminal surface inside the focused card shows a hollow / dimmed cursor via `ghostty_surface_set_focus(surface, false)` — which is the standard Ghostty behavior when the surface is not first responder.

## 3. Focus Layout Behavior (Left-Right / Top-Small / Top-Large)

### 3.1 Tab ring

```
[big terminal panel] → [mini card 0] → [mini card 1] → … → [mini card N-1] → [big terminal panel] …
```

Each mini card is an independent Tab stop.

### 3.2 Initial focus on `Cmd+E` entry

When transitioning `T → D` via `Cmd+E`, initial focus lands on the **big terminal panel** (which is the panel you were just typing in). The first `Tab` press then moves to the first mini card, which is the common case.

### 3.3 Return semantics

| Focused target | Action |
|---|---|
| Big terminal panel | Exit **D → T**. First responder restored to the panel's currently active split leaf. No layout or main change. |
| Mini card | Promote that card's worktree to the focus panel's main. Layout stays the same (Left-Right / Top-Small / Top-Large unchanged). Exit **D → T**. First responder given to the new main's active split leaf. |

### 3.4 Esc / Cmd+E cancel

Takes a snapshot of the first responder and the main worktree at the moment `T → D` happened, and restores both on `Esc` or `Cmd+E`. No side effects.

### 3.5 Delete

`Cmd+Backspace` / `Delete` on a focused mini card deletes the corresponding worktree via the existing flow. Big terminal panel is **not** deletable via this key in focus layouts — to avoid accidental deletion of the worktree the user is currently working in.

After delete, focus moves to the next mini card in the ring; if none remain, focus moves to the big terminal panel.

### 3.6 Visual feedback

- Focused target (card or big panel): 2px brand-cyan border + outer glow.
- Non-focused panels: 5% white dim overlay. This communicates clearly that keys are no longer being forwarded to the terminal.
- Terminal cursors in all surfaces become hollow / dimmed (Ghostty's built-in unfocused state).

## 4. New Worktree Dialog (`Cmd+N`) — Keyboard Support

### 4.1 Target behavior

| Situation | Key | Effect |
|---|---|---|
| Dialog opens | — | Focus automatically on the branch-name text field |
| Branch-name field filled | `Tab` | Focus → repo dropdown |
| Repo dropdown focused | `Space` or `↓` | Expand options |
| Repo dropdown expanded | `↑` `↓` | Navigate options |
| Repo dropdown expanded | `Return` | Select option, collapse |
| Repo dropdown focused (collapsed) | `Tab` | Focus → base-branch dropdown |
| Base-branch dropdown | — | Same behavior as repo dropdown |
| Any field (no dropdown expanded) | `Return` | Equivalent to clicking **Create** |
| Any field | `Esc` | Equivalent to clicking **Cancel** |

### 4.2 Implementation notes

`NSPopUpButton` supports full keyboard operation natively. If the dropdowns currently don't respond to Tab / arrow keys, the cause is one of:

1. The enclosing view or dialog overrides `acceptsFirstResponder` or has `refusesFirstResponder = true` in a parent.
2. The window's key-view loop (`nextKeyView` chain) is not configured.
3. `initialFirstResponder` is not set on the dialog window.

The fix is to correctly configure the dialog's window:

1. Set `window.initialFirstResponder = branchNameField`.
2. Call `window.recalculateKeyViewLoop()` after the view hierarchy is laid out.
3. Verify the dropdowns are not inside any container that refuses first responder.
4. Bind `Return` as the **Create** button's `keyEquivalent = "\r"` and `Esc` as the **Cancel** button's `keyEquivalent = "\u{1b}"` (or handle via the window's cancel action).

No architectural changes. Expected to be a small, surgical fix.

## 5. Implementation Sketch

### 5.1 Files touched

| File | Change |
|---|---|
| `Sources/App/MainWindowController.swift` | Add `Cmd+1..4` layout switch handlers and `Cmd+E` state toggle in `AmuxWindow.performKeyEquivalent`. Coordinate state transitions. |
| `Sources/UI/Dashboard/DashboardViewController.swift` | New `DashboardFocusController` (or extension) that owns the **D**-state focus ring: tracked index, next/prev, current focus target. Override `acceptsFirstResponder` on the dashboard container to allow Tab capture. Add `keyDown` handling for Tab / Shift+Tab / Return / Esc / Cmd+Backspace / Delete. Implement the snapshot+restore on Esc. |
| `Sources/UI/Dashboard/MiniCardView.swift` | Add a `isKeyboardFocused: Bool` property that drives the border and glow. |
| `Sources/UI/Dashboard/FocusPanelView.swift` | Same `isKeyboardFocused` property on the big panel. |
| `Sources/UI/Dialog/NewBranchDialog.swift` | Configure `initialFirstResponder`, `recalculateKeyViewLoop()`, and button `keyEquivalent` for Create / Cancel. |
| `Sources/App/TabCoordinator.swift` or `DashboardViewController.swift` | Track "last-used focus layout" (per project tab) in memory, used by §2.3. |

### 5.2 State-snapshot struct

A tiny value type held by the dashboard during **D** state:

```swift
private struct DashboardFocusSnapshot {
    let firstResponder: NSResponder?
    let focusedWorktreePath: String?
    let layout: DashboardLayout
}
```

Captured on `T → D`, consulted on Esc to restore `firstResponder`.

### 5.3 Grid Return drill-in

Implemented by:

1. Looking up the "last-used focus layout" (default Left-Right).
2. Calling the existing layout-switch code path (`showLayout(_:)` or similar).
3. Calling the existing "select worktree as main" code path with the focused card's worktree.
4. Making the new main's active split leaf first responder.

No new layout-switching or worktree-promotion logic; this only wires Tab+Return to existing entry points.

### 5.4 Terminal first-responder guard

`DashboardViewController` must override `acceptsFirstResponder` to return `true` in Grid mode (so Tab stays captured), and return `false` in focus layouts when **D** is not active (so terminals keep capturing keys). The state machine dictates which applies.

### 5.5 Cursor dimming

No explicit work — Ghostty already sets hollow / dimmed cursor when `ghostty_surface_set_focus(_, false)` is called. Since **D** state moves first responder off `GhosttyNSView`, the Ghostty focus-resign path fires automatically through `resignFirstResponder` → `ghostty_surface_set_focus(surface, false)`.

## 6. Testing Strategy

### 6.1 Unit tests

- `DashboardFocusController` Tab-ring logic: given N cards, `next()` / `prev()` wraps correctly, delete shifts focus appropriately.
- Snapshot / restore: capture then restore yields the same first responder and main worktree.
- "Last-used focus layout" tracking across layout switches.

### 6.2 Integration / UI tests (XCTest UI)

- In Grid layout, after app launch, Tab moves the visible focus ring; `Return` switches to Left-Right with the correct card promoted.
- `Cmd+2` → `Cmd+E` → Tab moves off the big terminal onto a mini card; `Return` promotes it.
- `Cmd+E` → `Esc` restores the original first responder (verified by sending a keystroke and asserting it reaches the terminal).
- New-branch dialog: on open, branch-name field is focused; Tab moves through repo → base branch → buttons; `Return` creates; `Esc` cancels.

### 6.3 Manual verification checklist

- `Cmd+1..4` all switch layouts without crashing.
- `Cmd+E` in Grid is a no-op.
- `Cmd+Backspace` in **D** triggers the existing delete confirmation dialog (not a new one).
- After delete, focus lands on a sensible next card.
- Dim overlay appears only in **D** in focus layouts, never in **T**.
- Tab in **T** state still sends `\t` to the PTY (regression check).
- Existing `Cmd+Option+Arrow` split-pane focus movement unchanged (regression check).

## 7. Risks and Open Questions

- **First-responder churn during state transitions** could interact badly with Ghostty's async focus callbacks. Mitigation: defer `makeFirstResponder` calls via `DispatchQueue.main.async`, matching the pattern already used elsewhere in amux.
- **Cmd+1..4 conflicts:** These are currently unused, but if the user later wants `Cmd+1..4` to switch project tabs (iTerm-style), we would need to rebind. Acceptable trade-off for now.
- **Delete confirmation:** Relies on the existing `TerminalCoordinator` + `DialogPresenter` flow. If that flow is presentation-only and doesn't hand back a Future/callback, we may need a small adapter to know when deletion finished so we can update focus.
- **Scroll-into-view:** When Tab moves to a mini card that is off-screen in the sidebar scroller, the scroller must scroll it into view. Needs a small `scrollToVisible(_:)` call on focus change.
