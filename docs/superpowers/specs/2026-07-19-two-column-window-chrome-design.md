# Two-column window chrome (no spanning title bar)

**Date:** 2026-07-19  
**Status:** Approved design — pending implementation plan  
**Approach:** C — new `WindowChromeController` shell (long-term maintainability)

## Problem

The main window still uses a **full-width title bar accessory** (`NSTitlebarAccessoryViewController` + `TitleBarView`) that spans both the dashboard column and the terminal. The desired layout is a strict **two-column** window:

1. Left sidebar = dashboard / worktree navigator  
2. Right = terminal area  
3. No chrome strip running across the full window width  
4. A single **draggable** vertical divider between the columns  

Traffic lights and tool icons must live in column headers, not in a spanning bar.

## Goals

- Remove the spanning title bar; embed chrome in column headers.
- Sidebar header: traffic lights left, tool icons right.
- Terminal header: `Repo · pane title` (icons + traffic lights join this header when the sidebar is collapsed).
- Draggable divider; persist sidebar width.
- Collapse sidebar with **⌘B** (not a separate layout “view mode”).
- Sidebar uses **macOS 26 Liquid Glass / vibrancy** (frosted translucent material).
- Worktree list **grouped by repo**: group header + two-line items (anatomy below).

## Non-goals

- Status bar redesign (stays full-width at the bottom).
- Right-side AI / notification panel changes.
- Migrating column resize to `NSSplitView`.
- Reworking split-pane terminal internals / Ghostty surface lifecycle beyond reparenting into the new chrome slots.
- Keeping the title-bar worktree **tab strip** / overflow menu.

## Settled decisions

| Topic | Decision |
|-------|----------|
| Worktree tabs in title bar | **Remove** — sidebar list is the only switcher |
| Header icons | Keep **Theme / First Mate / Files / Changes**; First Mate = navigator (§6), Files/Changes = side panel |
| Sidebar collapse | **⌘B** (+ matching menu/button); not `ViewMode` as layout mode |
| Terminal top chrome | **Yes** — `Repo · pane title` |
| Collapsed traffic lights | Move into **terminal header** left |
| Collapsed icons | **Stay visible** in terminal header (left of title) |
| Architecture | **C** — `WindowChromeController` owns chrome; Dashboard is content |
| Sidebar material | macOS 26 **frosted glass / vibrancy** |
| Worktree list | Group by **repo**; item layout below |

---

## Design

### 1. Window architecture

New **`WindowChromeController`** (`Sources/UI/Chrome/` or `Sources/App/`) owns the window content shell:

```
+------------------+--+---------------------------+
| SidebarHeader    |  | TerminalHeader            |
| ●●●      icons   |│ | Repo · pane title          |
+------------------+  +---------------------------+
| Sidebar content  |│ | Terminal / focus panel     |
| (glass)          |  | (opaque)                  |
|                  |│ |                           |
+------------------+--+---------------------------+
| StatusBar (full width, unchanged)               |
+-------------------------------------------------+
```

When sidebar collapsed (⌘B):

```
+-------------------------------------------------+
| ●●●  icons          Repo · pane title     [〉]   |
+-------------------------------------------------+
| Terminal (full width)                           |
+-------------------------------------------------+
```

**`MainWindowController`:**

- Keep `fullSizeContentView` + `titleVisibility = .hidden`.
- Remove `NSTitlebarAccessoryViewController` / spanning `TitleBarView`.
- Embed `WindowChromeController` in `contentContainer`.
- Reposition `standardWindowButton`s into the **active** header (sidebar header when expanded; terminal header when collapsed).
- Register **View → Toggle Sidebar** with key equivalent **⌘B** (also handled in `AmuxWindow` if needed so it wins over pane key routing).

**Dashboard** becomes content only: provides the sidebar overview view and the terminal focus/split host into chrome slots. It no longer owns column width constraints or collapse chrome.

### 2. SidebarHeader

Same row, ~36–40pt tall, aligned with TerminalHeader:

- **Left:** system traffic lights (repositioned `standardWindowButton`s — no fake buttons).
- **Right:** Theme · First Mate · Files · Changes (migrated from `TitleBarView`).
- **Icon → sidebar content (preserve today’s product mapping):**
  - **First Mate** ↔ §6 repo-grouped worktree navigator (today’s overview / First Mate column). This is the **default** left pane.
  - **Files / Changes** ↔ existing `WorktreeSidePanelViewController` host (not the navigator list).
  - **Theme** ↔ appearance toggle only; no pane change.
  - Mutual exclusive active tint among First Mate / Files / Changes.
  - ⌘B collapses the **whole** left column regardless of which pane is active; it does not change the selected pane. Opening from collapsed via ⌘B restores the last pane, or defaults to First Mate/navigator (same spirit as today’s `toggleSidebarDefaultDashboard`).
- When no worktree is selected, Files / Changes stay visible but disabled at 0.3 alpha; First Mate/navigator remains available.
- Optional **sidebar.left** icon as mouse affordance for ⌘B (recommended).

### 3. TerminalHeader

**Expanded:**

- Shows `{Repo} · {pane title}`.
  - **Repo:** project display name for the selected worktree.
  - **Pane title:** focused split leaf display label; fall back to worktree title / branch if missing.
  - Clamp with existing title helpers; full path is not required in the header (tooltip/status bar OK).

**Collapsed (⌘B):**

```
[traffic lights]  [Theme · First Mate · Files · Changes]  {Repo} · {pane title}  …  [expand]
```

Icons remain available; title sits after icons; expand control mirrors ⌘B.

**Data flow:** on worktree select / pane focus change, call `chrome.updateTerminalTitle(repo:pane:)` (replaces `refreshFocusedWorktreeCapsule` + tab strip refresh).

### 4. Divider + width + collapse

- Single vertical divider between columns (1px visual, wider hit target). Custom drag (not `NSSplitView`).
- Default width ~300 (current `leftColumnWidth`); min ~200; max ~50% of window.
- Persist as `Config.sidebarWidth` (`sidebar_width`), `decodeIfPresent`, default 300.
- `isSidebarCollapsed` owned by chrome; animate width (respect Reduce Motion → instant).
- Retire layout meaning of `DashboardViewController.ViewMode.split/terminal`. Keyboard NORMAL/INSERT (or equivalent) should subscribe to chrome collapse / focus region instead of treating terminal-only as a separate layout mode. Thin compatibility shims OK during migration.

### 5. Sidebar material (macOS 26 glass)

- Sidebar column (header + content) uses system **vibrancy / Liquid Glass** material appropriate for a navigation sidebar on macOS 26 (Tahoe)+.
- Terminal column stays **opaque** (terminal readability).
- On older OS versions where the target material is unavailable, fall back to the closest `NSVisualEffectView` sidebar material already used elsewhere in the app (or a solid `SemanticColors.panel`) — document the fallback in the plan; do not block the feature on 26-only APIs if the deployment target remains lower.

### 6. Worktree list (grouped)

Replace the current overview row presentation for the **default navigator pane** with a **repo-grouped** list inside the glass sidebar.

**Section label:** e.g. `WORKTREES` (exact copy flexible).

**Group header (not part of the item card):** repo name (`SailorDisplayInfo.project` / repo display name). Multiple worktrees under the same repo share one header.

**Item (per worktree) — exactly two content rows:**

```
●  current pane title                         time
   git diff                                   N panes
```

- **Status dot:** arbitrated agent status color (same semantics as today).
- **Current pane title:** focused/primary pane summary for that worktree (session title / worktree title resolver); not the group name.
- **Time:** compact age since last activity.
- **Git diff:** `+adds −dels` / `↑ahead↓behind` when present; muted “clean” or empty when none.
- **N panes:** leaf count.
- **Selected:** rounded rect highlight (Cursor-like), not a left accent bar requirement.
- Keep bottom **composer** in the navigator pane unless a follow-up explicitly removes it.
- Tap selects worktree / focuses terminal as today.
- **Grouping change:** list is ordered/grouped by **repo**, not by agent status. Preserve idle-worktree collapse/expander behavior if it still applies (idle items may sit in an expandable “Idle” section within or after groups — plan must not silently drop it; default = preserve).
- Orders carousel may remain below the list; out of scope to redesign ORDERS.

### 7. Migration map

| Piece | Action |
|-------|--------|
| `NSTitlebarAccessoryViewController` | Remove |
| `TitleBarView` tab strip / overflow / centered title | Delete |
| `TitleBarView` icons + delegates | Move into `SidebarHeaderView` / collapsed terminal header |
| `DashboardViewController` column width / collapse | Move to chrome |
| `DashboardOverviewView` list rows | Rebuild as grouped list under glass |
| `refreshWorktreeTabs` | Delete with tabs |
| `Config.sidebarWidth` | Add |
| UITest page objects (`TitleBarPage`, etc.) | Update accessibility ids |

### 8. Testing

- Unit: width clamp; collapse state; title string assembly; `sidebarWidth` config round-trip; repo grouping order.
- UI: drag divider; ⌘B expand/collapse; collapsed header shows icons + lights; traffic lights clickable in both states; select grouped worktree row.
- Visual/manual: glass sidebar vs opaque terminal on macOS 26.

---

## Open implementation notes (not open product questions)

- Exact `NSVisualEffectView` / Liquid Glass API choice for the deployment target — decide in the plan against `MACOSX_DEPLOYMENT_TARGET`.
- Whether `TitleBarView.swift` is deleted vs reduced to a deprecated shim — prefer delete once call sites move.
- **Keyboard `titlebar` region:** in scope for this plan’s wiring — retarget to sidebar header (icons) / terminal header so region focus does not point at a removed accessory. Deep shortcut redesign is out of scope.

## Interaction summary (⌘B vs icons)

| Action | Effect |
|--------|--------|
| ⌘B / sidebar button | Toggle left column collapsed; does not change active left pane. From collapsed, reopen last pane or default to First Mate/navigator |
| First Mate | Show §6 navigator in the left column (expand if collapsed). Click again when already active may collapse (today’s toggleSide behavior — preserve) |
| Files / Changes | Show side-panel host for that tab (expand if collapsed); same toggle-to-collapse when already active |
| Theme | Toggle appearance; no pane change |
| Click worktree row | Select worktree; terminal shows that tree |

## Success criteria

- No full-width title bar accessory.
- Two columns with one draggable divider; width persists.
- ⌘B collapses sidebar; lights + icons relocate to terminal header; title remains visible.
- Sidebar is translucent glass; terminal is opaque.
- Default navigator shows worktrees under repo group headers with the two-line item layout above.
- Header icons: First Mate ↔ navigator; Files/Changes ↔ side panel; Theme independent.
