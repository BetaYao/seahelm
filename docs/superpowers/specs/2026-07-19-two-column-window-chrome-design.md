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
- Worktree list **grouped by repo**, with a fixed three-line item anatomy.

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
| Header icons | Keep **Theme / First Mate / Files / Changes** |
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
- **Right:** Theme · First Mate · Files · Changes (migrated from `TitleBarView`; mutual exclusive active tint; overview/no-worktree disables Files/Changes/First Mate at 0.3 alpha as today).
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

Replace the current overview row presentation for the navigator with a **repo-grouped** list inside the glass sidebar.

**Section label:** e.g. `WORKTREES` (exact copy flexible).

**Group header:** repo name (`SailorDisplayInfo.project` / repo display name).

**Item (per worktree), three lines under the group:**

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
- Keep bottom **composer** in the sidebar content unless a follow-up explicitly removes it.
- Tap selects worktree / focuses terminal as today.

Orders carousel behavior can remain below the list if it already lives in the overview; out of scope to redesign ORDERS in this spec.

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
- Region-focus keyboard (`titlebar` region) should retarget to sidebar header / terminal header regions in a follow-up or the same plan’s keyboard task.

## Success criteria

- No full-width title bar accessory.
- Two columns with one draggable divider; width persists.
- ⌘B collapses sidebar; lights + icons relocate to terminal header; title remains visible.
- Sidebar is translucent glass; terminal is opaque.
- Worktrees appear under repo group headers with the three-line item layout above.
