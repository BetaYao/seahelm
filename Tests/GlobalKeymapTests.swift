import XCTest
import AppKit
@testable import seahelm

final class GlobalKeymapTests: XCTestCase {

    private func r(_ chars: String?, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags,
                   split: Bool = true) -> GlobalShortcut? {
        GlobalKeymap.resolve(chars: chars, keyCode: keyCode, flags: flags, hasSplitContext: split)
    }

    // MARK: - Split shortcuts (gated on split context)

    func testCmdDSplitsHorizontal() {
        XCTAssertEqual(r("d", 2, .command), .splitHorizontal)
    }

    func testCmdShiftDSplitsVertical() {
        XCTAssertEqual(r("D", 2, [.command, .shift]), .splitVertical)
    }

    func testCmdOptionArrowsMoveFocus() {
        XCTAssertEqual(r(nil, 123, [.command, .option]), .moveFocus(.left))
        XCTAssertEqual(r(nil, 124, [.command, .option]), .moveFocus(.right))
        XCTAssertEqual(r(nil, 125, [.command, .option]), .moveFocus(.down))
        XCTAssertEqual(r(nil, 126, [.command, .option]), .moveFocus(.up))
    }

    func testArrowFlagsWithNumericPadStillMatch() {
        XCTAssertEqual(r(nil, 123, [.command, .option, .numericPad, .function]), .moveFocus(.left))
    }

    func testCmdCtrlArrowsResize() {
        XCTAssertEqual(r(nil, 123, [.command, .control]), .resize(.left))
        XCTAssertEqual(r(nil, 124, [.command, .control]), .resize(.right))
        XCTAssertEqual(r(nil, 125, [.command, .control]), .resize(.down))
        XCTAssertEqual(r(nil, 126, [.command, .control]), .resize(.up))
    }

    func testCmdCtrlEqualsResetsRatio() {
        XCTAssertEqual(r("=", 24, [.command, .control]), .resetRatio)
    }

    func testSplitShortcutsSuppressedWithoutSplitContext() {
        XCTAssertNil(r("d", 2, .command, split: false))
        XCTAssertNil(r(nil, 123, [.command, .option], split: false))
        XCTAssertNil(r("=", 24, [.command, .control], split: false))
    }

    // MARK: - Always-available shortcuts

    func testCtrlTabCyclesWorktree() {
        XCTAssertEqual(r(nil, 48, .control), .nextWorktree)
        XCTAssertEqual(r(nil, 48, [.control, .shift]), .prevWorktree)
    }

    func testWorktreeCycleAvailableWithoutSplitContext() {
        XCTAssertEqual(r(nil, 48, .control, split: false), .nextWorktree)
    }

    func testCmdBTogglesSidebar() {
        XCTAssertEqual(r("b", 11, .command), .toggleSidebar)
        XCTAssertEqual(r("b", 11, .command, split: false), .toggleSidebar)
    }

    func testCmdEscExitsInsert() {
        XCTAssertEqual(r(nil, 53, .command), .exitInsert)
    }

    // MARK: - Non-matches

    func testPlainEscDoesNotResolve() {
        XCTAssertNil(r(nil, 53, []))   // plain Esc passes to terminal
    }

    func testUnmodifiedLetterDoesNotResolve() {
        XCTAssertNil(r("d", 2, []))
    }

    func testPlainTabDoesNotResolve() {
        XCTAssertNil(r(nil, 48, []))
    }
}
