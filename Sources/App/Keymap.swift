import Foundation

enum Keymap {
    /// Bare-key chords for the dashboard nav ring. Callers reach this only when the
    /// dashboard owns the keyboard, so there is no mode to check — a pane with focus
    /// never routes its keys here in the first place.
    static func action(chord: KeyChord) -> KeyboardAction? {
        if let c = chord.char {
            switch c {
            case "h": return .moveFocus(.left)
            case "j": return .moveFocus(.down)
            case "k": return .moveFocus(.up)
            case "l": return .moveFocus(.right)
            case "i": return .enterTerminal
            case "d": return .deleteFocused
            case "c": return .toggleChanges
            case "f": return .toggleFiles
            case "m": return .toggleFirstMate
            case "n": return .newWorktree
            case "1"..."9":
                if let n = Int(c) { return .jumpToCard(n - 1) }
                return nil
            default: return nil
            }
        }
        if let kc = chord.keyCode {
            switch kc {
            case 36: return .enterTerminal       // Return
            case 123: return .moveFocus(.left)   // Left arrow
            case 124: return .moveFocus(.right)  // Right arrow
            case 125: return .moveFocus(.down)   // Down arrow
            case 126: return .moveFocus(.up)     // Up arrow
            default: return nil
            }
        }
        return nil
    }
}
