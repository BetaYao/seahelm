# Compact mode: collapse fleet + pane tabs

Date: 2026-11-14  
Clients: AppKit (macOS) and GPUI (macOS / Windows / Linux)  
Status: design

## Goal

When the main window’s content width shrinks past a threshold, enter a **compact** presentation:

1. The left fleet column **collapses** (same chrome collapse as ⌘B).
2. The current worktree’s terminals are shown as **pane tabs** — one pane visible at a time — so the remaining width stays usable.

Widen past a higher exit threshold and leave compact: restore spatial splits and restore the left column according to the user’s stored collapse preference (not “always expand”).

## Non-goals

- Worktree-level tabs (fleet does not become a tab strip).
- Height-based triggers.
- Changing `SplitTree` persistence or seahelm-core layout RPCs — compact is **presentation only**.
- Coupling to the macOS Island; island sizing stays independent.
- A separate “compact sidebar width”; collapse means width → 0 via existing chrome.

## Product decisions (locked)

| Decision | Choice |
|----------|--------|
| Tab grain | **Pane tabs only** |
| Fleet in compact | Auto-collapse; switch worktrees via ⌘B / header expand (existing), not via tabs |
| Exit fleet policy | Respect user `sidebar_collapsed` / GPUI `sidebar_visible` preference at exit — auto-collapse does **not** overwrite that preference |
| Split shortcuts in compact | Still allowed; new leaf appears as a tab and becomes active |
| Edit mode (AppKit) | Share the same zoom + terminal tab strip; do not stack a second strip |

## State

Introduce a client-local flag, conceptually:

```text
compactActive: Bool          // derived from width + hysteresis, not persisted
userSidebarCollapsed: Bool   // existing preference (AppKit: config; GPUI: in-memory today)
paneTabSelection: LeafId?    // which pane tab is shown; defaults to focused leaf
```

**Sidebar collapse** is edge-triggered so ⌘B can still peek the fleet while compact:

- **Enter compact:** force chrome collapsed **without** writing `userSidebarCollapsed`.
- **Exit compact:** restore chrome to `userSidebarCollapsed`.
- **Explicit ⌘B / header pane toggle:** updates `userSidebarCollapsed` and the live chrome; expanding while compact is allowed (peek). Re-entering the enter threshold does nothing until an exit/enter cycle.

Steady-state intent remains `compact ∨ user preference` on auto transitions; continuous enforcement of that OR would block peek.

**Pane presentation** while compact (and while AppKit edit mode’s terminal strip is up):

- Exactly one leaf is “zoomed” / full-bleed in the terminal column.
- A tab strip lists every leaf of the current worktree’s `SplitTree`.
- Selecting a tab focuses that leaf and zooms it.
- Closing a tab closes that pane (same as today’s close-leaf).

Spatial `SplitTree` ratios remain unchanged underneath; leaving compact clears zoom and lays out the full tree again.

## Width trigger

Measure **main window content width** (AppKit: content view / chrome host width; GPUI: `viewport_size().width`), not screen size.

| | Width (points) |
|--|----------------|
| Enter compact | `width < 760` |
| Exit compact | `width ≥ 820` |

Hysteresis band: 760–819 keeps the current mode so edge dragging does not flicker.

Re-evaluate on resize end and on live resize throttled (~1 frame / 50ms). During AppKit live resize, defer surface re-embed the same way chrome collapse already does (`GhosttyBridge.beginLiveResize` / existing collapse deferral).

Thresholds are constants in one place per client (easy to tune); no config key in v1.

## Tab strip

### Content

For each leaf in tree order (same order as edit-mode strip / split leaf walk):

- Status dot (agent status colour, same as fleet / pane chrome).
- Label: custom pane title if set, else short agent/session title; prefix `#n` when seahelm-core has minted a handle.
- Active tab = focused + zoomed leaf.

### Placement

- **AppKit:** hoist into `TerminalHeaderView` via existing `EditTabStripView` (same path edit mode uses: `editStripsProvider` / `chromeEditStrips`). Show the terminal strip whenever `compactActive || editMode`; preview strip still only in edit mode.
- **GPUI:** add a pane tab row in the terminal column header when compact (or when the worktree has >1 leaf and compact). Keep existing `preview_tabs` (“Terminals” + file tabs). When a preview file tab is active, pane tabs are hidden or disabled until the user returns to “Terminals” — same priority as today (preview replaces the terminal body).

### Single-pane worktrees

With only one leaf, still collapse the fleet in compact, but **omit** the pane tab strip (nothing to switch). Zoom is unnecessary; layout is already full-bleed.

## Client mapping

### AppKit

| Concern | Hook |
|---------|------|
| Width observation | `MainWindowController` / content view bounds (or `WindowChromeController` layout) |
| Collapse SSOT | `ChromeLayoutState` — auto path must not persist `sidebar_collapsed` |
| Zoom | `SplitContainerView.setZoom(leafId:on:)` (already used by `selectTerminalTab`) |
| Strip UI | `EditTabStripView` on `TerminalHeaderView` |
| Enter edit while compact | No-op for terminal strip; preview column behaviour unchanged |
| Leave compact while edit | Keep edit strip; only clear “compact-driven” zoom if edit also clears it on exit — prefer: zoom stays while edit or compact |

Focus / keyboard: pane tab cycle can mirror edit mode’s next-terminal-tab if one exists; otherwise Cmd+]/+] / existing focus-move among leaves still updates zoom target when compact.

### GPUI

| Concern | Hook |
|---------|------|
| Width observation | `Workspace` on window resize / `render` size |
| Collapse | `sidebar_visible` — auto toggle must keep a separate `user_sidebar_visible` (or only flip visibility when entering/exiting without clobbering a stored preference; add persistence later if macOS already has it) |
| Zoom | New presentation flag on the terminal column: when compact and >1 leaf, draw only the focused leaf’s frame as full body (do not rewrite `SplitTree`). Selecting another pane tab sets `tree.focused` and repaints |
| Strip UI | New small tab strip above `panes_body` / in terminal header; not worktree-scoped fleet tabs |
| Preview | Unchanged; `preview_tabs` wins over pane body |

GPUI today has no `setZoom`; compact introduces **view-only zoom** (render filter), not a tree mutation.

## Interactions

| Feature | Behaviour in compact |
|---------|----------------------|
| ⌘B | Toggles **user** preference and effective visibility. Expanding while compact is allowed (peek at fleet); collapsing again is fine. Exiting compact does not force-hide if the user expanded during compact and we treat that expand as `userSidebarCollapsed = false` — **rule:** any explicit ⌘B / header toggle updates the user preference; auto enter/exit only adjusts effective visibility |
| Files / Changes | Header icons still open left panes (expand left column). Closing them returns to fleet pane tag but `effectiveCollapsed` follows compact again if still narrow |
| Island (AppKit) | Unaffected |
| First Mate / Settings (GPUI) | Still replace the right main area; pane tabs irrelevant until those close |
| Sleep / wake pane | Asleep panes remain in the tab strip (dimmed), same as edit strip |
| Fork / away indicator | Stay on terminal header chrome, not on the tab label (v1) |

## Edge cases

1. **Resize through the band quickly** — hysteresis + evaluate on resize end prevents enter/exit storms.
2. **Multi-window (if ever)** — per window; no global compact flag.
3. **Worktree switch while compact** — new worktree’s strip rebuilds; zoom target = that tree’s focused leaf; fleet stays collapsed.
4. **Last pane closed** — same as non-compact (worktree empty / placeholder policy unchanged).
5. **Split while compact** — create leaf, focus it, zoom it, select its tab.
6. **External layout sync** (`layouts.set` / restore) — apply tree first, then re-apply zoom to focused leaf if compact.

## Testing (intent)

- Unit / pure: hysteresis enter/exit given a sequence of widths.
- AppKit: compact with 2+ panes shows strip and zoom; widen restores split frames; `sidebar_collapsed` in config unchanged by auto-enter.
- GPUI: same presentation checks; preview tab still covers terminals.
- UI: drag width across 760/820; ⌘B during compact; Files open/close during compact.

## Implementation order (suggested)

1. Shared behaviour spec constants + hysteresis helper (can be duplicated per client; no shared crate required).
2. AppKit: wire width → compact flag → collapse without persisting; show `EditTabStripView` + `setZoom` outside edit mode.
3. GPUI: `user_sidebar_visible` vs effective; view-only zoom + pane tab strip.
4. Polish: tab labels (`#n`, custom title), single-pane strip omission, live-resize deferral parity.

## Open for later (out of v1)

- Config override for thresholds / disable compact.
- Persist GPUI sidebar collapsed like AppKit.
- Status / fork badges on tab titles.
- seahelm-web parity.
