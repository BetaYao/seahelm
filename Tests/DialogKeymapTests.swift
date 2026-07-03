import XCTest
import AppKit
@testable import seahelm

final class DialogKeymapTests: XCTestCase {

    private func r(_ chars: String?, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [],
                   vim: Bool = false) -> DialogNav? {
        DialogKeymap.resolve(chars: chars, keyCode: keyCode, flags: flags, allowVimKeys: vim)
    }

    func testArrowsAlwaysNavigate() {
        XCTAssertEqual(r(nil, 126), .up)
        XCTAssertEqual(r(nil, 125), .down)
    }

    func testReturnAndKeypadEnterConfirm() {
        XCTAssertEqual(r(nil, 36), .confirm)
        XCTAssertEqual(r(nil, 76), .confirm)
    }

    func testEscCancels() {
        XCTAssertEqual(r(nil, 53), .cancel)
    }

    func testVimKeysDisabledByDefault() {
        XCTAssertNil(r("k", 40))
        XCTAssertNil(r("j", 38))
    }

    func testVimKeysWhenEnabled() {
        XCTAssertEqual(r("k", 40, vim: true), .up)
        XCTAssertEqual(r("j", 38, vim: true), .down)
    }

    func testArrowsWorkEvenWithVimDisabled() {
        XCTAssertEqual(r(nil, 126, vim: false), .up)
    }

    func testModifierCombosPassThrough() {
        XCTAssertNil(r(nil, 126, [.command]))
        XCTAssertNil(r(nil, 36, [.control]))
    }

    func testShiftAllowedForNavigation() {
        // Shift+Return / Shift+arrows still navigate (shift is stripped for matching).
        XCTAssertEqual(r(nil, 126, [.shift]), .up)
        XCTAssertEqual(r(nil, 36, [.shift]), .confirm)
    }

    func testPrintableTextPassesThrough() {
        XCTAssertNil(r("a", 0))
        XCTAssertNil(r("a", 0, vim: true))   // 'a' is not a vim nav key
    }

    func testNumericPadFunctionFlagsOnArrowsStillNavigate() {
        XCTAssertEqual(r(nil, 125, [.numericPad, .function]), .down)
    }
}
