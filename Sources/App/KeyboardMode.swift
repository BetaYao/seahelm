import Foundation

/// There is deliberately no keyboard mode, and no transient substate either since the
/// inline create form went. Whether bare keys navigate is decided by who owns keyboard
/// focus — the dashboard's `keyDown` only runs when the dashboard is first responder,
/// and `RegionFocusController` tracks the region. A separate mode flag was a second
/// name for `chromeState.isCollapsed` and could only drift from it.

/// Still the vocabulary for split-pane focus/resize (`GlobalKeymap`), which is
/// the only place directions survive: the fleet list no longer has a bare-key
/// nav ring — `⌃⇥` / `⌃⇧⇥` cycle worktrees and the mouse does the rest.
enum FocusDirection: Equatable { case left, right, up, down }
