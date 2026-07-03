import AppKit

/// A normalized navigation intent inside a modal dialog (Quick Switcher, Settings,
/// confirmation sheets). Unifies the per-dialog key handling so every modal reads the
/// same keys (docs/keyboard-redesign.md §8).
enum DialogNav: Equatable {
    case up
    case down
    case confirm
    case cancel
}

enum DialogKeymap {
    /// Resolve a key event to a dialog navigation intent, or nil to let it fall through
    /// (e.g. printable text that should filter a search field).
    ///
    /// `allowVimKeys` enables `k`/`j` as up/down — only safe when no text field owns the
    /// event (a search field must keep `j`/`k` as literal input). Arrow keys, Return, and
    /// Esc are always recognized.
    static func resolve(
        chars: String?,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        allowVimKeys: Bool
    ) -> DialogNav? {
        // Only bare keys (or Shift) navigate; Cmd/Ctrl/Option combos pass through.
        guard flags.subtracting([.numericPad, .function, .shift]).isEmpty else { return nil }

        switch keyCode {
        case 126: return .up        // Up arrow
        case 125: return .down      // Down arrow
        case 36, 76: return .confirm // Return, Enter (keypad)
        case 53: return .cancel     // Esc
        default: break
        }

        if allowVimKeys {
            switch chars {
            case "k": return .up
            case "j": return .down
            default: break
            }
        }
        return nil
    }
}
