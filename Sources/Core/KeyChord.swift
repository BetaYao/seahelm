import Foundation

/// A key press named in text — `a`, `3`, `slash`, `f5`, `ctrl+c`, `shift+tab`,
/// `alt+left` — with what it takes to deliver it either way: as a key event
/// Ghostty encodes for the terminal's current keyboard mode, or as the bytes a
/// legacy xterm would send, for a pane that has no surface to encode with.
///
/// Every key goes in as a key, never as text: text is the terminal's paste
/// path, and a TUI reads a pasted `3` as pasted text — Claude's question dialog
/// ignores it, so the Return after it picked the row under the cursor.
///
/// Grammar: modifiers (`ctrl`, `alt`/`option`, `shift`) joined to one key by
/// `+`. Keys are letters, digits, the US punctuation characters or their names
/// (`minus`, `equal`, `left-bracket`, `right-bracket`, `semicolon`, `quote`,
/// `backslash`, `comma`, `period`, `slash`, `backtick`), and `enter`, `tab`,
/// `space`, `escape`, `backspace`, `delete`, `insert`, `home`, `end`, `pageup`,
/// `pagedown`, the arrows and `f1`–`f12`. Case is insignificant except for a
/// lone character: `A` and `?` are typed as shift+a and shift+slash.
struct KeyChord: Equatable {
    enum Key: Equatable {
        /// A key that types a character: letter, digit, punctuation, space.
        case character(Character)
        case enter, tab, escape, backspace, delete, insert, home, end, pageUp, pageDown
        case up, down, left, right
        case function(Int)
    }

    var key: Key
    var ctrl = false
    var alt = false
    var shift = false

    init(key: Key, ctrl: Bool = false, alt: Bool = false, shift: Bool = false) {
        self.key = key
        self.ctrl = ctrl
        self.alt = alt
        self.shift = shift
    }

    init?(_ spec: String) {
        // A lone character is taken literally, case and all.
        if spec.count == 1, let c = spec.first {
            if let base = Self.unshifted[c] {
                self.init(key: .character(base), shift: true)
                return
            }
            if c.isUppercase, c.isASCII, let lower = c.lowercased().first {
                self.init(key: .character(lower), shift: true)
                return
            }
            guard Self.keycodes[c] != nil else { return nil }
            self.init(key: .character(c))
            return
        }
        var parts = spec.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // `ctrl++` names the plus key itself.
        if parts.count >= 2, parts.suffix(2) == ["", ""] { parts.removeLast(2); parts.append("+") }
        guard let name = parts.popLast(), !name.isEmpty, let parsed = Self.parseKey(name) else { return nil }
        self.init(key: parsed.key, shift: parsed.shift)
        for modifier in parts {
            switch modifier {
            case "ctrl", "control": guard !ctrl else { return nil }; ctrl = true
            case "alt", "option", "opt", "meta": guard !alt else { return nil }; alt = true
            case "shift": shift = true
            default: return nil
            }
        }
    }

    private static func parseKey(_ name: String) -> (key: Key, shift: Bool)? {
        switch name {
        case "enter", "return": return (.enter, false)
        case "tab": return (.tab, false)
        case "space": return (.character(" "), false)
        case "esc", "escape": return (.escape, false)
        case "backspace", "bs": return (.backspace, false)
        case "delete", "del": return (.delete, false)
        case "insert", "ins": return (.insert, false)
        case "home": return (.home, false)
        case "end": return (.end, false)
        case "pageup", "pgup": return (.pageUp, false)
        case "pagedown", "pgdn": return (.pageDown, false)
        case "up": return (.up, false)
        case "down": return (.down, false)
        case "left": return (.left, false)
        case "right": return (.right, false)
        default: break
        }
        if let c = punctuationNames[name] {
            if let base = unshifted[c] { return (.character(base), true) }
            return (.character(c), false)
        }
        if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...12).contains(n) { return (.function(n), false) }
        guard name.count == 1, let c = name.first else { return nil }
        if let base = unshifted[c] { return (.character(base), true) }
        return keycodes[c] != nil ? (.character(c), false) : nil
    }

    /// Whether the key types a character (letter, digit, punctuation, space).
    var isCharacter: Bool {
        if case .character = key { return true }
        return false
    }

    // MARK: - As a key event

    /// The macOS virtual keycode (kVK_*) Ghostty is handed.
    var keycode: UInt32 {
        switch key {
        case .character(let c): return Self.keycodes[c] ?? 0
        case .enter: return 36
        case .tab: return 48
        case .escape: return 53
        case .backspace: return 51
        case .delete: return 117
        case .insert: return 114  // kVK_Help sits where Insert is on a PC keyboard
        case .home: return 115
        case .end: return 119
        case .pageUp: return 116
        case .pageDown: return 121
        case .up: return 126
        case .down: return 125
        case .left: return 123
        case .right: return 124
        case .function(let n): return Self.functionKeycodes[n - 1]
        }
    }

    /// What the key reports with no modifiers, as AppKit does: the character,
    /// or the private-use code AppKit gives a function key.
    var unshiftedCodepoint: UInt32 {
        switch key {
        case .character(let c): return c.unicodeScalars.first.map { $0.value } ?? 0
        case .enter: return 0x0d
        case .tab: return 0x09
        case .escape: return 0x1b
        case .backspace: return 0x7f
        case .delete: return 0xF728
        case .insert: return 0xF727
        case .home: return 0xF729
        case .end: return 0xF72B
        case .pageUp: return 0xF72C
        case .pageDown: return 0xF72D
        case .up: return 0xF700
        case .down: return 0xF701
        case .left: return 0xF702
        case .right: return 0xF703
        case .function(let n): return 0xF703 + UInt32(n)
        }
    }

    /// The text the key types, as a keyboard would hand it over with the key
    /// event: the character (shifted if shift is held). Nil for keys that type
    /// nothing, and under ctrl, where Ghostty derives the control code itself.
    var text: String? {
        guard !ctrl, case .character(let c) = key else { return nil }
        return String(shift ? Self.shifted(c) : c)
    }

    /// Modifiers that went into producing `text` — shift, when it changed the
    /// character. Ghostty does not re-apply consumed modifiers when it encodes.
    var consumesShift: Bool { text != nil && shift }

    // MARK: - As bytes

    /// What a legacy xterm sends for this key, for writing straight into a zmx
    /// session. Nil for a combination with no legacy encoding (ctrl+5).
    var bytes: String? {
        let esc = "\u{1b}"
        // xterm's modifier parameter: 1 + shift + 2·alt + 4·ctrl.
        let param = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
        func csi(_ final: String) -> String { param == 1 ? "\(esc)[\(final)" : "\(esc)[1;\(param)\(final)" }
        func tilde(_ n: Int) -> String { param == 1 ? "\(esc)[\(n)~" : "\(esc)[\(n);\(param)~" }

        switch key {
        case .up: return csi("A")
        case .down: return csi("B")
        case .right: return csi("C")
        case .left: return csi("D")
        case .home: return csi("H")
        case .end: return csi("F")
        case .insert: return tilde(2)
        case .delete: return tilde(3)
        case .pageUp: return tilde(5)
        case .pageDown: return tilde(6)
        case .function(let n):
            if n <= 4 {
                let final = ["P", "Q", "R", "S"][n - 1]
                return param == 1 ? "\(esc)O\(final)" : "\(esc)[1;\(param)\(final)"
            }
            return tilde([15, 17, 18, 19, 20, 21, 23, 24][n - 5])
        case .tab:
            return shift ? "\(esc)[Z" : (alt ? esc : "") + "\t"
        case .enter:
            return (alt ? esc : "") + "\r"
        case .escape:
            return (alt ? esc : "") + esc
        case .backspace:
            return (alt ? esc : "") + (ctrl ? "\u{08}" : "\u{7f}")
        case .character(let c):
            let typed: String
            if ctrl {
                guard let code = Self.controlCode(c) else { return nil }
                typed = String(UnicodeScalar(code))
            } else {
                typed = String(shift ? Self.shifted(c) : c)
            }
            return (alt ? esc : "") + typed
        }
    }

    /// ctrl+<key> in the C0 range: letters, and the keys the ASCII table pairs
    /// with the remaining control codes.
    private static func controlCode(_ c: Character) -> UInt8? {
        guard let a = c.asciiValue else { return nil }
        switch c {
        case "a"..."z": return a - 96
        case " ", "2", "`": return 0      // ^@
        case "[", "3": return 0x1b         // ^[
        case "\\", "4": return 0x1c
        case "]", "5": return 0x1d
        case "6": return 0x1e
        case "-", "7", "/": return 0x1f
        case "8": return 0x7f
        default: return nil
        }
    }

    // MARK: - US layout tables

    private static func shifted(_ c: Character) -> Character {
        if let s = shiftedPunctuation[c] { return s }
        return c.uppercased().first ?? c
    }

    private static let shiftedPunctuation: [Character: Character] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "-": "_", "=": "+", "[": "{", "]": "}", ";": ":", "'": "\"", "\\": "|", ",": "<", ".": ">",
        "/": "?", "`": "~",
    ]
    private static let unshifted: [Character: Character] =
        Dictionary(uniqueKeysWithValues: shiftedPunctuation.map { ($0.value, $0.key) })

    private static let punctuationNames: [String: Character] = [
        "minus": "-", "equal": "=", "left-bracket": "[", "right-bracket": "]", "semicolon": ";",
        "quote": "'", "backslash": "\\", "comma": ",", "period": ".", "slash": "/", "backtick": "`",
        "plus": "+",
    ]

    /// kVK_ANSI_* for every key that types a character on a US keyboard.
    private static let keycodes: [Character: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "-": 27, "=": 24, "]": 30, "[": 33, "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44, ".": 47,
        "`": 50, " ": 49,
    ]

    private static let functionKeycodes: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
}
