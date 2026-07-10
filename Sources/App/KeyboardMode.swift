import Foundation

enum KeyboardMode: Equatable {
    case normal
    case insert
}

/// Transient state within Normal mode.
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
