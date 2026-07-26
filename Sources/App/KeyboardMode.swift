import Foundation

/// A transient interaction that changes what bare keys mean for as long as it lasts.
///
/// There is deliberately no NORMAL/INSERT mode. Whether bare keys navigate is decided
/// by who owns keyboard focus — the dashboard's `keyDown` only runs when the dashboard
/// is first responder, and `RegionFocusController` tracks the region. A separate mode
/// flag was a second name for `chromeState.isCollapsed` and could only drift from it.
enum KeyboardSubstate: Equatable {
    case none
    case deletePending(agentId: String)   // first `d` pressed, awaiting confirm
    case createForm                        // inline worktree creator focused
}

enum FocusDirection: Equatable { case left, right, up, down }

enum KeyboardAction: Equatable {
    case moveFocus(FocusDirection)
    case jumpToCard(Int)        // 0-based
    case enterTerminal
    case deleteFocused
    case showChanges
    case browseFiles
    case newWorktree
    case toggleFiles        // f: toggle Files side panel
    case toggleChanges      // c: toggle Changes side panel
    case toggleFirstMate    // m: toggle First Mate side panel
}

/// A normalized key identity. Either a printable char (no modifiers) or a raw keyCode.
struct KeyChord: Hashable {
    let char: String?
    let keyCode: UInt16?
    init(char: String) { self.char = char; self.keyCode = nil }
    init(keyCode: UInt16) { self.char = nil; self.keyCode = keyCode }
}
