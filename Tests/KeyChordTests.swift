import XCTest
@testable import seahelm

final class KeyChordTests: XCTestCase {
    /// Named keys reach a live surface as key presses: typed, the terminal's
    /// paste path turned ESC and ^C into spaces, and a TUI ignores a pasted
    /// digit — Claude's question dialog then took the Return after it as
    /// "pick the highlighted row".
    func testEveryKeyIsAKeyPress() {
        XCTAssertEqual(KeyChord("esc")?.keycode, 53)
        XCTAssertEqual(KeyChord("Escape")?.unshiftedCodepoint, 0x1b)
        XCTAssertEqual(KeyChord("ctrl+v")?.keycode, 9, "the keycode sendImagePasteKey uses")
        XCTAssertEqual(KeyChord("down")?.keycode, 125)
        XCTAssertEqual(KeyChord("3")?.keycode, 20)
        XCTAssertEqual(KeyChord("3")?.text, "3")
        XCTAssertEqual(KeyChord("space")?.text, " ")
        XCTAssertEqual(KeyChord("f5")?.keycode, 96)
        XCTAssertEqual(KeyChord("f12")?.unshiftedCodepoint, 0xF70F)
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            XCTAssertNotNil(KeyChord("ctrl+\(letter)"), String(letter))
        }
    }

    func testModifiersParse() {
        XCTAssertEqual(KeyChord("ctrl+c"), KeyChord(key: .character("c"), ctrl: true))
        XCTAssertEqual(KeyChord("Shift+Tab"), KeyChord(key: .tab, shift: true))
        XCTAssertEqual(KeyChord("option+left"), KeyChord(key: .left, alt: true))
        XCTAssertEqual(KeyChord("ctrl+alt+shift+f3"), KeyChord(key: .function(3), ctrl: true, alt: true, shift: true))
        for bad in ["", "ctrl+", "hyper+a", "ctrl+ctrl+a", "f13", "ctrl+cc", "é"] {
            XCTAssertNil(KeyChord(bad), bad)
        }
    }

    /// A lone character keeps its case and its shift: `?` is shift+slash.
    func testLoneCharactersAreTakenLiterally() {
        XCTAssertEqual(KeyChord("A"), KeyChord(key: .character("a"), shift: true))
        XCTAssertEqual(KeyChord("?"), KeyChord(key: .character("/"), shift: true))
        XCTAssertEqual(KeyChord("+"), KeyChord(key: .character("="), shift: true))
        XCTAssertEqual(KeyChord("plus"), KeyChord(key: .character("="), shift: true))
        XCTAssertEqual(KeyChord("ctrl++"), KeyChord(key: .character("="), ctrl: true, shift: true))
        XCTAssertEqual(KeyChord("slash"), KeyChord(key: .character("/")))
        XCTAssertEqual(KeyChord("?")?.text, "?")
        XCTAssertEqual(KeyChord("?")?.consumesShift, true)
        XCTAssertEqual(KeyChord("shift+tab")?.consumesShift, false, "shift on a key that types nothing stays live")
    }

    func testCtrlTypesNoText() {
        XCTAssertNil(KeyChord("ctrl+c")?.text, "Ghostty derives ^C from the key, not from text")
        XCTAssertNil(KeyChord("up")?.text)
    }

    /// The zmx fallback writes these straight into the session.
    func testLegacyBytes() {
        XCTAssertEqual(KeyChord("esc")?.bytes, "\u{1b}")
        XCTAssertEqual(KeyChord("ctrl+c")?.bytes, "\u{03}")
        XCTAssertEqual(KeyChord("ctrl+[")?.bytes, "\u{1b}")
        XCTAssertEqual(KeyChord("3")?.bytes, "3")
        XCTAssertEqual(KeyChord("A")?.bytes, "A")
        XCTAssertEqual(KeyChord("alt+b")?.bytes, "\u{1b}b")
        XCTAssertEqual(KeyChord("up")?.bytes, "\u{1b}[A")
        XCTAssertEqual(KeyChord("ctrl+right")?.bytes, "\u{1b}[1;5C")
        XCTAssertEqual(KeyChord("shift+tab")?.bytes, "\u{1b}[Z")
        XCTAssertEqual(KeyChord("delete")?.bytes, "\u{1b}[3~")
        XCTAssertEqual(KeyChord("pagedown")?.bytes, "\u{1b}[6~")
        XCTAssertEqual(KeyChord("f1")?.bytes, "\u{1b}OP")
        XCTAssertEqual(KeyChord("shift+f1")?.bytes, "\u{1b}[1;2P")
        XCTAssertEqual(KeyChord("f5")?.bytes, "\u{1b}[15~")
        XCTAssertNil(KeyChord("ctrl+9")?.bytes, "no legacy encoding")
        XCTAssertEqual(ControlKeys.bytes(for: "é"), "é", "a character with no key is sent as itself")
        XCTAssertNil(ControlKeys.bytes(for: "enter"))
    }
}
