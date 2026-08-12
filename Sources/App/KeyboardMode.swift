import Foundation

/// A transient interaction that changes what bare keys mean for as long as it lasts.
///
/// There is deliberately no NORMAL/INSERT mode. Whether bare keys navigate is decided
/// by who owns keyboard focus — the dashboard's `keyDown` only runs when the dashboard
/// is first responder, and `RegionFocusController` tracks the region. A separate mode
/// flag was a second name for `chromeState.isCollapsed` and could only drift from it.
enum KeyboardSubstate: Equatable {
    case none
    case createForm   // inline worktree creator focused
}

/// Still the vocabulary for split-pane focus/resize (`GlobalKeymap`), which is
/// the only place directions survive: the fleet list no longer has a bare-key
/// nav ring — `⌃⇥` / `⌃⇧⇥` cycle worktrees and the mouse does the rest.
enum FocusDirection: Equatable { case left, right, up, down }
