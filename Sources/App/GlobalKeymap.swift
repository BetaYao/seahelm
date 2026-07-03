import AppKit

/// A window-level shortcut resolved from a raw key event, independent of AppKit event
/// plumbing. Centralizes what used to be inline `if` chains in
/// `SeahelmWindow.performKeyEquivalent` so the mapping is a single, unit-tested source of
/// truth (docs/keyboard-redesign.md §6.3 — the retained Cmd aliases).
enum GlobalShortcut: Equatable {
    case splitHorizontal
    case splitVertical
    case moveFocus(FocusDirection)
    case resize(FocusDirection)
    case resetRatio
    case toggleSidebar
    case exitInsert            // Cmd+Esc: INSERT → NORMAL (D1)
    case nextWorktree          // Ctrl+Tab
    case prevWorktree          // Ctrl+Shift+Tab
}

enum GlobalKeymap {
    /// Resolve a key event to a global shortcut. `chars` is `charactersIgnoringModifiers`
    /// (preserves keyboard-layout behavior for letter chords). Split-only shortcuts
    /// require `hasSplitContext`. Returns nil when nothing matches (event passes through).
    ///
    /// Precedence mirrors the original handler: split shortcuts first (gated), then the
    /// always-available worktree cycle, sidebar toggle, and insert-exit.
    static func resolve(
        chars: String?,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        hasSplitContext: Bool
    ) -> GlobalShortcut? {
        // Arrow keys carry .numericPad/.function on macOS; strip for modifier matching.
        let base = flags.subtracting([.numericPad, .function])
        let lower = chars?.lowercased()

        if hasSplitContext {
            if flags == .command && chars == "d" { return .splitHorizontal }
            if flags == [.command, .shift] && lower == "d" { return .splitVertical }

            if base == [.command, .option] {
                switch keyCode {
                case 123: return .moveFocus(.left)
                case 124: return .moveFocus(.right)
                case 125: return .moveFocus(.down)
                case 126: return .moveFocus(.up)
                default: break
                }
            }

            if base == [.command, .control] {
                switch keyCode {
                case 123: return .resize(.left)
                case 124: return .resize(.right)
                case 125: return .resize(.down)
                case 126: return .resize(.up)
                default: break
                }
            }

            if flags == [.command, .control] && chars == "=" { return .resetRatio }
        }

        if keyCode == 48 {   // Tab
            if flags == .control { return .nextWorktree }
            if flags == [.control, .shift] { return .prevWorktree }
        }

        if flags == .command && chars == "b" { return .toggleSidebar }

        if flags == .command && keyCode == 53 { return .exitInsert }   // Cmd+Esc

        return nil
    }
}
