import XCTest
@testable import seahelm

final class KeymapTests: XCTestCase {
    func testNavigationKeys() {
        XCTAssertEqual(Keymap.action(chord: KeyChord(char: "h")), .moveFocus(.left))
        XCTAssertEqual(Keymap.action(chord: KeyChord(char: "j")), .moveFocus(.down))
        XCTAssertEqual(Keymap.action(chord: KeyChord(char: "k")), .moveFocus(.up))
        XCTAssertEqual(Keymap.action(chord: KeyChord(char: "l")), .moveFocus(.right))
    }

    func testNumberJump() {
        XCTAssertEqual(Keymap.action(chord: KeyChord(char: "1")), .jumpToCard(0))
        XCTAssertEqual(Keymap.action(chord: KeyChord(char: "9")), .jumpToCard(8))
    }

    func testActionKeys() {
        XCTAssertEqual(Keymap.action(chord: KeyChord(char: "i")), .enterTerminal)
        XCTAssertEqual(Keymap.action(chord: KeyChord(char: "d")), .deleteFocused)
        XCTAssertEqual(Keymap.action(chord: KeyChord(char: "c")), .toggleChanges)
        XCTAssertEqual(Keymap.action(chord: KeyChord(char: "f")), .toggleFiles)
        XCTAssertEqual(Keymap.action(chord: KeyChord(char: "m")), .toggleFirstMate)
        XCTAssertEqual(Keymap.action(chord: KeyChord(char: "n")), .newWorktree)
    }

    func testArrowsMirrorHJKL() {
        XCTAssertEqual(Keymap.action(chord: KeyChord(keyCode: 123)), .moveFocus(.left))
        XCTAssertEqual(Keymap.action(chord: KeyChord(keyCode: 124)), .moveFocus(.right))
        XCTAssertEqual(Keymap.action(chord: KeyChord(keyCode: 125)), .moveFocus(.down))
        XCTAssertEqual(Keymap.action(chord: KeyChord(keyCode: 126)), .moveFocus(.up))
    }

    func testReturnEntersTerminal() {
        XCTAssertEqual(Keymap.action(chord: KeyChord(keyCode: 36)), .enterTerminal)
    }

    func testUnmappedReturnsNil() {
        XCTAssertNil(Keymap.action(chord: KeyChord(char: "z")))
    }
}
