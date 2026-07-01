# Move the worktree list from a floating popover into a left-sidebar tab

**Date:** 2026-07-01
**Status:** Approved design — pending implementation plan

## Problem

The cross-project worktree/agent list currently appears as a **floating popover**
(`worktreePopover`, an `NSPopover` in `DashboardViewController`) anchored to the
title-bar worktree icon. The user wants it to stop floating and instead live in
the **left sidebar** as a tab alongside **File** and **Changes**.

## Current structure

- **Floating panel:** `DashboardViewController.worktreePopover` (`.transient`).
  Its content is `leftRightSidebarScroll` — a scroll view of cross-project
  `StackedMiniCardContainerView` mini-cards, built/refreshed by
  `populateWorktreeCards()`. Opened via `toggleWorktreePopover(from:)` from the
  title-bar worktree icon.
- **Left sidebar:** `WorktreeSidePanelViewController` (`sidePanelVC`), hosted in a
  300pt `leftColumnContainer`. Tabs are a `SidePanelTab` enum
  (`firstMate`/`files`/`changes`); `rebuildContent()` builds the active tab's
  content. Its own `tabBar` is hidden — tab switching is driven by title-bar
  pane icons through `DashboardViewController.selectLeftPane(_ pane: LeftPane)`,
  which maps a `LeftPane` to `sidePanelVC.selectTab(...)` **and expands the left
  column if collapsed**.

## Decisions (settled)

- Tab name: **Worktrees**.
- Clicking the title-bar worktree icon **expands the column and opens the tab**
  (reuses `selectLeftPane`'s existing expand-on-collapse behavior).

## Design

### 1. New sidebar tab: `.worktrees`

Add `SidePanelTab.worktrees` (new raw value, e.g. `3`). Unlike `files`/`changes`
(scoped to the selected worktree), this tab is **global** — it shows all
worktrees/agents across projects. It becomes the sidebar's "navigator" section.

### 2. The card list moves into the sidebar, dashboard stays its owner

The mini-card list is dashboard-owned data (`SailorDisplayInfo`, tap-to-select
behavior, continuous status refresh). Rather than duplicate that in the sidebar,
the dashboard **provides** the list view and the sidebar **embeds** it for the
`.worktrees` tab:

- `WorktreeSidePanelViewController` gains `var worktreesTabView: NSView?` — the
  view shown for the `.worktrees` tab. `rebuildContent()` embeds it (or a
  "No worktrees" placeholder if nil).
- `DashboardViewController` sets `sidePanelVC.worktreesTabView =
  leftRightSidebarScroll` during setup and keeps it populated: call
  `populateWorktreeCards()` when the `.worktrees` tab activates and on each
  status update while it is active (today the popover only populated on open).
- `leftRightSidebarScroll` is reparented into the sidebar's content area when the
  tab is active and removed when switching away; the dashboard retains the
  reference so it can keep refreshing it.

### 3. Title-bar icon selects the tab instead of opening a popover

- Add `.worktrees` to the `LeftPane` enum; `selectLeftPane(.worktrees)` maps to
  `sidePanelVC.selectTab(.worktrees)` (column-expand is already handled there).
- The title-bar worktree icon's action changes from `toggleWorktreePopover(...)`
  to `selectLeftPane(.worktrees)`.
- Remove `worktreePopover`, `toggleWorktreePopover(from:)`, and
  `closeWorktreePopover()`. `populateWorktreeCards()` is retained (now feeds the
  sidebar tab).

### 4. Tap-to-select behavior

The mini-cards already select their worktree on tap (existing
`StackedMiniCardContainerView` behavior). No change needed — selecting from the
sidebar tab switches the active worktree exactly as it did from the popover.

## Non-goals (YAGNI)

- No change to the dashboard's main focus-panel / mini-card layout.
- No change to `files`/`changes`/`firstMate` tab content.
- No new unified left-column tab-bar UI; keep driving tab switches from the
  existing title-bar pane icons.
- No change to the card visuals or the idle-collapse behavior.

## Testing

- `SidePanelTab.worktrees` is selectable and `rebuildContent()` embeds the
  provided `worktreesTabView` (unit-testable via the existing
  `selectedTabForTesting` hook + a stub view).
- Selecting `.worktrees` when the column is collapsed expands it
  (`selectLeftPane` behavior — existing).
- Manual: title-bar worktree icon opens the sidebar tab (no popover); the list
  refreshes as agent statuses change; tapping a card switches worktree.

## Impact

- The `NSPopover` and its two toggle methods are removed (~30 lines).
- One reparented scroll view; no new card-rendering code.
- Behavior change: the worktree list is now a persistent sidebar tab rather than
  a transient popover — it stays visible until another tab is chosen.
