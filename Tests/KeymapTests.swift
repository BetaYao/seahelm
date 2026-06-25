import XCTest
@testable import seahelm

final class KeymapTests: XCTestCase {
    func testNormalNavigationKeys() {
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "h")), .moveFocus(.left))
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "j")), .moveFocus(.down))
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "k")), .moveFocus(.up))
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "l")), .moveFocus(.right))
    }

    func testNormalNumberJump() {
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "1")), .jumpToCard(0))
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "9")), .jumpToCard(8))
    }

    func testNormalActionKeys() {
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "i")), .enterTerminal)
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "d")), .deleteFocused)
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "c")), .showChanges)
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "f")), .browseFiles)
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "n")), .newWorktree)
    }

    func testReturnEntersTerminal() {
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(keyCode: 36)), .enterTerminal)
    }

    func testUnmappedReturnsNil() {
        XCTAssertNil(Keymap.action(mode: .normal, chord: KeyChord(char: "z")))
    }

    func testInsertModeHasNoNormalBindings() {
        XCTAssertNil(Keymap.action(mode: .insert, chord: KeyChord(char: "h")))
    }
}
