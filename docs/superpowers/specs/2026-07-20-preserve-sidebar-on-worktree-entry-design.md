# Preserve Sidebar State When Entering a Worktree

## Goal

Entering a worktree must not change whether the left sidebar is expanded or collapsed. This applies to every entry path, including the island, dashboard rows, notifications, and other navigation actions that enter terminal mode.

## Design

Remove the automatic left-column collapse from the shared `.terminal` view-mode transition in `DashboardViewController`. The transition will continue to close the First Mate overview surface, hide the overview, update the committed worktree, and focus the terminal, but it will leave `isLeftColumnCollapsed` and its width constraints unchanged.

Manual sidebar controls remain unchanged. If the sidebar is expanded before entering a worktree, it stays expanded. If it is collapsed, it stays collapsed.

## Scope

- Do not add Island-specific navigation flags or special cases.
- Do not change Dashboard or split-mode layout behavior.
- Do not change manual sidebar toggling, left-pane selection, or Island closing behavior.
- Do not introduce unrelated layout refactoring.

## Testing

Add regression coverage for both state transitions:

- Entering terminal mode with an expanded sidebar keeps it expanded.
- Entering terminal mode with a collapsed sidebar keeps it collapsed.

Run the focused tests and a Debug build to verify the AppKit target still compiles.
