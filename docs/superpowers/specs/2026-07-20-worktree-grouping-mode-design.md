# Worktree Grouping Mode Design

## Goal

Add a grouping control to the right side of the First Mate header so users can organize worktree rows by repository, status, or last activity time. The selected mode persists across app launches.

## Scope

- Add one grouping button and native menu to the First Mate header.
- Support repository, status, and activity-time grouping.
- Preserve existing worktree selection, row actions, and keyboard navigation.
- Persist the last selected grouping mode.
- Do not add global keyboard shortcuts or replace the existing stack-based list.

## Architecture

Introduce a pure grouping model outside the AppKit rendering code:

- `WorktreeGroupingMode` defines `.repository`, `.status`, and `.activityTime`.
- `WorktreeGroup` contains a stable identifier, display title, optional status presentation, and its ordered worktrees.
- `WorktreeGrouping.groups(sailors:mode:now:)` transforms `[SailorDisplayInfo]` into deterministically ordered sections.

`DashboardOverviewView` owns the current mode, asks the grouping model for sections, and renders those sections using the existing stack and row views. It rebuilds `orderedRows` in rendered order so the current keyboard navigation model continues to work without a second ordering source.

The selected worktree is anchored by ID/path across a mode change. After rebuilding, the view restores its highlight and scroll visibility at the worktree's new position. It falls back to the first row only when that worktree no longer exists.

## Activity Data

Add `lastActivityAt: Date?` to `SailorDisplayInfo`. `TabCoordinator` supplies the same authoritative value already used elsewhere:

```swift
statusAggregator.lastActivity(for: agent.worktreePath) ?? agent.startedAt
```

Grouping uses this date directly. It must not parse the localized display string such as `"2h"`, and it must not rely solely on activity events, which may be empty even when persisted activity exists.

## Grouping And Ordering

### Repository

- Group by repository display name.
- Preserve repository groups in first-seen order, which follows the configured card/workspace order.
- Preserve the current within-repository behavior: main worktree first, then linked worktrees by directory creation time from oldest to newest.
- Use worktree path as the stable tie-breaker when creation times match.
- Empty repository names share an `Unknown repository` group.

### Status

- Roll up pane states with `SailorStatus.highestPriority`, so the status identity follows the existing `Waiting > Error > Exited > Running > Idle > Unknown` pane arbitration.
- Order groups as: Needs input, Running, Idle, Error, Dormant, Unknown.
- Map `.exited` to the Dormant group; all other statuses map to their matching group.
- Order worktrees within each group by `lastActivityAt` descending, then worktree path ascending.

### Activity Time

Calculate buckets against the injected `now` value so boundaries are deterministic and testable:

1. Recent hour: activity less than 60 minutes old.
2. Today: activity at least 60 minutes old but on the same local calendar day as `now`.
3. Recent 7 days: activity before today but less than 7 times 24 hours old.
4. Earlier: known activity at least 7 times 24 hours old.
5. No activity: no known activity date.

Order buckets as listed. Order worktrees within each bucket by activity descending, then worktree path ascending. Rows with no activity sort by path.

Future timestamps are clamped into the Recent hour bucket rather than creating another group.

## Header Interaction

Add an unbordered icon button at the far right of the existing First Mate header row. Use the `rectangle.3.group` SF Symbol, sized and tinted to match the existing header controls. If that symbol is unavailable, fall back to a compact `☷` text glyph.

Clicking the button opens a native `NSMenu` with:

- Group by Repository
- Group by Status
- Group by Time

The active item has a checkmark. Selecting an item closes the menu, rebuilds the worktree list immediately, updates the button tooltip/accessibility label, and persists the raw mode value in `UserDefaults`.

The button does not join the overview's arrow-key focus ring. Native menu keyboard behavior remains available, but this feature adds no global shortcuts.

## Persistence And Compatibility

Use the dedicated `seahelm.dashboard.worktreeGroupingMode` `UserDefaults` key for the grouping mode. The default is repository grouping, matching the current user-facing layout. Missing or invalid stored values silently fall back to repository mode.

The grouping preference is presentation-only and does not belong in the repository/workspace configuration model.

## Rendering

Each `WorktreeGroup` maps to the existing group-header plus vertical rows-box structure:

- Repository headers show the repository name.
- Status headers reuse existing status glyphs, colors, and labels.
- Time headers use neutral header styling and the approved labels: Recent hour, Today, Recent 7 days, Earlier, No activity.

Existing `RowView` behavior is unchanged. Repo tags may remain visible in status and time modes; in repository mode they may be omitted when redundant, matching the current grouped-by-repo appearance.

## Testing

Pure unit tests cover:

- Repository first-seen ordering, main-worktree priority, and creation-time row ordering.
- Status arbitration, fixed status order, and recency sorting.
- All activity buckets, including exact 60-minute and 7-day boundaries.
- Same-day handling, missing dates, and future timestamps.
- Stable path tie-breakers.
- Preference decoding and invalid-value fallback.

Focused AppKit tests cover:

- The header exposes all three menu items.
- The active menu item is checked.
- Choosing an item updates and persists the mode.
- `orderedRows` matches rendered group order after each mode switch.
- Selection remains anchored to the same worktree after regrouping.

Run the focused grouping and dashboard tests first, then the full `seahelmTests` scheme. If repository-level Ghostty linking remains unavailable, report that infrastructure failure separately from focused pure-model test results.
