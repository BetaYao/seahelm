# macOS client visual spec

Extracted from the Swift sources (paths relative to `Sources/`) so the GPUI client can match the AppKit window. Re-check against the code when they drift.

## Shared tokens

**Font:** JetBrains Mono is used everywhere via `AppFont.mono(size:weight:)`, falling back to the system monospaced font (`UI/Shared/AppFont.swift:10,29`).

**Colours** (dark / light, from `UI/Shared/SemanticColors.swift`):

| Token | Dark | Light | Line |
|---|---|---|---|
| text ("ink") | #cfe0e0 | #1f232b | :54 |
| muted ("inkDim") | #7fa0a3 | #636b78 | :58 |
| subtle ("inkFaint") | #7fa0a3 | #717a88 | :62 |
| line | #96d7e1 | #c6cfdb | :66 |
| accent | #1fc8da | #0e9bb5 | :82 |
| running | #1bb062 | #1f9d63 | :70 |
| waiting | #5b93f0 | #2563eb | :74 |
| idle | #557170 | #8a93a1 | :78 |
| danger | #e84635 | #dc2626 | :86 |
| attention | #e0a458 | #d08706 | :91 |

## 1. Window (`App/MainWindowController.swift`)

- **Size:** 1200×800 content rect, minimum 600×400, frame autosaved as "SeahelmMainWindow" (:384–405).
- **Style mask:** `[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`.
- **Title bar:** `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, `isOpaque = false`, background `.clear`, no toolbar (:385–394, :1377).
- **Window background:** an `NSVisualEffectView`, material `.underWindowBackground`, `.behindWindow`, the same for both themes (:11–16, :1360).
- **Sidebar column:** the same vibrancy material (`UI/Chrome/WindowChromeController.swift:423`).
- **Terminal column:** solid Catppuccin background, Mocha #1e1e2e or Latte #eff1f5 (`Terminal/GhosttyBridge.swift:209`).
- **Traffic lights:** moved into a 70×14 slot in the sidebar header.
  - Slot: leading 12, vertically centred in the 40pt header (`UI/Chrome/SidebarHeaderView.swift:68–71`).
  - Buttons: placed left to right with 6pt spacing, y = (slotH − btnH)/2 (MainWindowController:1438–1445).
  - Full screen: the slot width becomes 0 and a brand mark shows instead (20×20 app icon + "Seahelm", system 13 semibold, #888888).
  - Sidebar collapsed: the slot moves into the terminal header.

## 2. Fleet column

**Width** (`UI/Chrome/ChromeLayoutMetrics.swift`): default 300, min 200, max = max(200, windowWidth × 0.5). Collapse with ⌘B animates over 0.24s with curve (0.32, 0.72, 0, 1) and fades alpha at the same time.

**Top toolbar** (`SidebarHeaderView`, height 40):
- Icons are right-aligned, trailing −8, stack spacing 2 (:53–77).
- `ChromeIconClusterView`: `circle.lefthalf.filled`, `sailboat`, `folder`, `plusminus`, then `sidebar.left`.
- Each icon: SF Symbol 12pt medium in a 26×26 borderless button with corner radius 7.
- Tint #888888. The active pane's icon uses the accent colour; Files/Changes drop to alpha 0.3 when there is no worktree (`ChromeIconClusterView.swift:52–119`).

**Fleet header** (`UI/Dashboard/DashboardOverviewView.swift:244–334`):
- Horizontal row, spacing 10, at top 13, leading/trailing 15. Contents:
  - "◍": mono 13, accent.
  - "Fleet": mono 12.5 bold, text colour.
  - Subtitle: mono 11, subtle. Formula: `running>0 ? "\(n) · \(running) running" : "\(n)"` (:601).
  - Spacer.
  - `folder.badge.plus` button.
  - `rectangle.3.group` button (grouping menu).
  - Both buttons: 13pt medium symbols, tint muted.
- Hairline 11pt below the row: full width, 1pt, rgba(150,215,225,0.10) dark / rgba(31,35,43,0.10) light (:69).
- The list starts 10 + bannerHeight (0 when empty) + 4 below the hairline. The stack has a 2pt top inset and 12pt bottom inset; rows are inset 15 left and right (:990).

**Group header** (:996–1067):
- Horizontal stack, spacing 7.
- Edge insets: top = 0 for the first group, 13 for the rest; bottom = 7.
- Project mode: title in mono 11 semibold, muted. Then a spacer, an optional `arrow.trianglehead.merge` button (14×14, shown when ≥3 items and no integration checkout), then `plus` and `xmark`. All three are 11pt medium, tint subtle, always visible.
- Status mode: a status glyph (mono 8) or a 9pt spinner, the title in mono 11 in the status colour, and the count in mono 11, subtle.
- Rows within a group are spaced 4 (:662). The outer stack spacing is 2.

**Worktree row** (`RowView`, :1262–1494):
- Layout:
  - Corner radius 8, clipped.
  - Text column: leading = dot trailing + 7, trailing −10, top/bottom padding 8.
  - Status dot: leading 10, vertically centred on line 1.
  - Line 1 and line 2 are 3pt apart.
  - Height ≈ 8 + ~16 (12pt line) + 3 + ~15 (11pt line) + 8 ≈ **50pt**. This is computed by Auto Layout, not a constant.
- Line 1 (spacing 7):
  - Title: mono 12 regular, text colour, truncated at the tail, one line.
  - Time: mono 10, subtle, right-aligned.
- Line 2 (spacing 8, first-baseline aligned):
  - Optional repo name: mono 10 semibold, `ProjectColor`. Shown only when not in project mode.
  - Branch/subtitle: mono 11, muted.
  - Git stats: mono 10. `+N` in #5fb87a, `−N` (U+2212) in #e07a6a separated by one space, then two spaces and `↑a↓b` in subtle.
  - Optional PR: `#12` in muted, then ✓ #5fb87a / ✕ #e07a6a / ● attention, then " approved" or " changes". Merged shows in #a371f7; closed/draft in subtle.
  - Spacer, then "`N panes`" (or "—"): mono 10, subtle.
- Fills, without a border:
  - Selected: white 10% (dark) / black 8% (light).
  - Hover: white 5% / black 4%.
  - The selection change cross-fades over 0.18s ease-in-out (:1313–1331).
- Label ribbon: 3pt wide at the left edge, inset 6pt top and bottom, radius 1.5.
- Pending: content at alpha 0.55 with a 0.75s pulse between the hover and selected fills.

**Status dot** (`Core/AgentStatus.swift`), glyphs drawn in mono 8:

| Status | Glyph | Colour |
|---|---|---|
| running | ◐ | running (shown as `SpinnerDotView`) |
| waiting | ● | attention |
| idle | ○ | idle |
| error | ✕ | danger |
| exited | ◌ | idle |
| unknown | ◌ | subtle |

- Running spinner: 9pt diameter, 1.5pt 270° arc, round caps, clockwise, 1.0s per turn. All spinners share one phase (`UI/Shared/SpinnerDotView.swift`).
- Unseen finish (idle with unread output): ● in waiting blue (:2103).
- Cleanup candidate: `trash` symbol at 9pt, muted.

**Time formatting:**
- While running: `compactDuration` of the round duration, giving "12s", "3m05s" or "1h02m".
- Otherwise `relativeAge`: "just now" under 10s, then "Ns", "Nm", "Nh", "Nd" (`UI/Shared/WorktreeRowHelpers.swift:13–44`, `App/TabCoordinator.swift:604`).

**Pane sub-rows** (Expand All Panes mode): indent 27, ● in mono 7, `#n` in mono 11 subtle, title in mono 11. Top/bottom padding 4, radius 6 (:1893).

## 3. Column divider (`UI/Chrome/ChromeDividerView.swift`)

- Takes no layout width: a 16pt hit strip centred on the seam, laid over both columns.
- Idle: a 1pt line in `NSColor.separatorColor`.
- Hover or drag: a 2pt accent line plus an accent fill at 10% across the strip; cursor is resize-left-right.
- Dragging changes the width, clamped as in §2.

## 4. Terminal side

**Header** (`UI/Chrome/TerminalHeaderView.swift`), height 40:
- Background equals the terminal background. In First Mate mode it is the background blended 16% toward the accent.
- Left: `square.and.arrow.up` (26×26, 12pt, #888888) at leading 12, then the memory label 6pt after it.
- Memory label: `monospacedDigitSystemFont` 11, `textSecondary` (muted). Format: "<1 MB", "%.0f MB" below 1024 MB, otherwise "%.1f GB" (:132).
- Title: system 12 semibold in the terminal foreground (#cdd6f4 Mocha / #4c4f69 Latte), truly centred.
  - Leading ≥ memory + 8.
  - Tail truncation; middle truncation when the title looks like a path.
- Right edge:
  - `square.split.2x1` (edit mode) at trailing −8. Tint: fg × 0.55; fg × 0.2 when disabled; accent with a 15% accent fill when on.
  - An optional `arrow.triangle.branch` 4pt to its left.

**Terminal panes:**
- The focus panel is flush with corner radius 0 (`UI/Dashboard/DashboardViewController.swift:839`).
- Keyboard-focus ring (dashboard navigation state only): 3pt accent border plus an accent glow (radius 10, opacity 0.6) (`UI/Dashboard/FocusPanelView.swift:37`).

**Splits:**
- Gap is 1pt; hit strip 16pt.
- Idle: `separatorColor` line. Hover: 2pt line in `controlAccentColor` with that colour at 10% as the strip fill.
- Ratio is clamped to 0.1–0.9; double-click calls the delegate (`UI/Split/DividerView.swift`).

**Inactive wash:**
- Applies to every non-focused leaf, only when there are 2+ leaves.
- Colour: white 8.5% (dark) / black 5.5% (light), fading over 0.12s (`Terminal/GhosttyNSView.swift:201`, `UI/Split/SplitContainerView.swift:264`).

## 5. First Mate dock (`UI/Dashboard/FirstMateDockView.swift`)

- Layout: `─(14pt) ⎈ [spinner] label ───(flex) [pause] ›`, spacing 6, column inset top 10, bottom 12, trailing −12. Height is about 37pt for one line.
- Rules: 1pt, line colour at α 0.22, or 0.45 on hover. They turn attention-coloured when it wants you.
- Mark: `steeringwheel` at 11pt medium.
- Label, all mono 11:
  - "First Mate": semibold; muted, or text colour on hover.
  - " · ": subtle.
  - Status word: medium, coloured by state.

| State | Word | Colour |
|---|---|---|
| off | "off" | subtle |
| starting | "starting" | subtle |
| idle | "watching" | accent |
| thinking | "working" | running (spinner shown) |
| needsYou | "needs you" | attention |
| paused | "paused" | subtle |

- Chevron: `chevron.right` at 10pt semibold; subtle, or text colour on hover.
- `pause.fill` / `play.fill` at 10pt appears only on hover.
- Hover fill: inset 4/6/6/6, radius 8, white 6% / black 5%.
- Second line (mono 11, attention) appears only in the wants-you state.

## 6. Terminal font and theme

- Bundled `Resources/ghostty.conf`: `font-family = JetBrains Mono`, falling back to `PingFang SC`, and `copy-on-select = false`.
- Font size and window padding are not set, so Ghostty's defaults apply: 13pt, padding 2. (These are Ghostty defaults from memory, not repo code; please confirm them.)
- Load order (`GhosttyBridge.buildConfig`):
  1. Ghostty's default files.
  2. The bundled conf.
  3. `~/.config/seahelm/ghostty.conf`. Your machine's copy sets `Sarasa Term SC` and its own theme line.
  4. A temporary file `theme = <bundle>/themes/Catppuccin Mocha|Latte` (:370–388).
- Dark vs light comes from the `terminal_theme_mode` setting (default "app") resolved against the app's appearance; `theme_mode` defaults to "system".

## 7. Grouping and the data contract

**Grouping modes** (`UI/Dashboard/WorktreeGrouping.swift`), stored in UserDefaults key `seahelm.dashboard.worktreeGroupingMode`:
- `repository` (default): main first, then the integration checkout, then by creation date.
- `status`: Needs input, [Finished], Running, Idle, Error, Dormant, Unknown; sorted by activity, newest first.
- `activityTime`: Recent hour, Today, Recent 7 days, Earlier, No activity.
- `pane`: project grouping plus pane sub-rows for worktrees with 2+ panes.

**Control-socket method:** `fleet.groups`, params `{mode: "repository"|"status"|"activity"|"pane"}` (`Core/ControlProtocol.swift:580`, `App/TabCoordinator.swift:2547`). Response:

```
{ mode, groups: [ { id: "repository:<name>"|"status:<Raw>"|"status:unseen"|"activity:<bucket>",
    title, status?: "Running"|"Idle"|…, unseen?: true,
    items: [ { id, worktree_path, repository, status, is_main_worktree,
               last_activity_at?: epoch, running_since?: epoch, unseen?: true,
               title, subtitle,
               pr?: { number, url, state, checks?, review? } } ] } ] }
```

**Missing from the payload:** git stats (+/−, ↑↓), pane count, the formatted time, label colour, cleanup flag, and per-pane rows. No other control method I checked sends git stats or pane count. A client can work out the time itself: from `running_since` while running, otherwise from `last_activity_at` using the formulas in §2. The "1 running" subtitle comes from per-worktree rolled-up status, which is not the same as the item's `status` field (that one is the highest-priority pane status).## Shared tokens