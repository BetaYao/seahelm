import XCTest
@testable import seahelm

final class LeaderMenuTests: XCTestCase {

    // MARK: - entries / hints

    func testRootEntries() {
        let keys = LeaderMenu.entries(at: []).map(\.key)
        XCTAssertEqual(keys, ["s", "n", "d", "g", "w", "c", "f", "/", "?"])
    }

    func testSubmenuEntries() {
        let keys = LeaderMenu.entries(at: ["s"]).map(\.key)
        XCTAssertEqual(keys, ["s", "v", "x", "="])
    }

    func testGoSubmenuEntries() {
        let keys = LeaderMenu.entries(at: ["g"]).map(\.key)
        XCTAssertEqual(keys, ["w", "0", "b"])
    }

    func testEntriesOnCommandPathIsEmpty() {
        // 'n' is a leaf command, not a submenu.
        XCTAssertTrue(LeaderMenu.entries(at: ["n"]).isEmpty)
    }

    func testEntriesOnUnknownPathIsEmpty() {
        XCTAssertTrue(LeaderMenu.entries(at: ["zzz"]).isEmpty)
        XCTAssertTrue(LeaderMenu.entries(at: ["s", "zzz"]).isEmpty)
    }

    func testHintsMirrorEntriesWithSubmenuFlag() {
        let hints = LeaderMenu.hints(at: [])
        XCTAssertEqual(hints.first, LeaderHint(key: "s", label: "split ▸", isSubmenu: true))
        XCTAssertEqual(hints.first(where: { $0.key == "n" }),
                       LeaderHint(key: "n", label: "new worktree", isSubmenu: false))
    }

    // MARK: - resolve

    func testResolveDescend() {
        XCTAssertEqual(LeaderMenu.resolve(path: [], key: "s"), .descend)
        XCTAssertEqual(LeaderMenu.resolve(path: [], key: "g"), .descend)
        XCTAssertEqual(LeaderMenu.resolve(path: [], key: "w"), .descend)
    }

    func testResolveFireTopLevelCommand() {
        XCTAssertEqual(LeaderMenu.resolve(path: [], key: "n"), .fire(.newWorktree))
        XCTAssertEqual(LeaderMenu.resolve(path: [], key: "d"), .fire(.deleteWorktree))
        XCTAssertEqual(LeaderMenu.resolve(path: [], key: "c"), .fire(.showChanges))
        XCTAssertEqual(LeaderMenu.resolve(path: [], key: "f"), .fire(.browseFiles))
        XCTAssertEqual(LeaderMenu.resolve(path: [], key: "/"), .fire(.commandPalette))
        XCTAssertEqual(LeaderMenu.resolve(path: [], key: "?"), .fire(.keyboardHelp))
    }

    func testResolveFireInSplitSubmenu() {
        XCTAssertEqual(LeaderMenu.resolve(path: ["s"], key: "s"), .fire(.splitHorizontal))
        XCTAssertEqual(LeaderMenu.resolve(path: ["s"], key: "v"), .fire(.splitVertical))
        XCTAssertEqual(LeaderMenu.resolve(path: ["s"], key: "x"), .fire(.closePane))
        XCTAssertEqual(LeaderMenu.resolve(path: ["s"], key: "="), .fire(.resetRatio))
    }

    func testResolveFireInGoSubmenu() {
        XCTAssertEqual(LeaderMenu.resolve(path: ["g"], key: "w"), .fire(.quickSwitcher))
        XCTAssertEqual(LeaderMenu.resolve(path: ["g"], key: "0"), .fire(.dashboard))
        XCTAssertEqual(LeaderMenu.resolve(path: ["g"], key: "b"), .fire(.toggleSidebar))
    }

    func testResolveResizeDirections() {
        XCTAssertEqual(LeaderMenu.resolve(path: ["w"], key: "H"), .fire(.resize(.left)))
        XCTAssertEqual(LeaderMenu.resolve(path: ["w"], key: "J"), .fire(.resize(.down)))
        XCTAssertEqual(LeaderMenu.resolve(path: ["w"], key: "K"), .fire(.resize(.up)))
        XCTAssertEqual(LeaderMenu.resolve(path: ["w"], key: "L"), .fire(.resize(.right)))
        XCTAssertEqual(LeaderMenu.resolve(path: ["w"], key: "m"), .fire(.maximizePane))
    }

    func testResolveUnknownKey() {
        XCTAssertEqual(LeaderMenu.resolve(path: [], key: "z"), .unknown)
        XCTAssertEqual(LeaderMenu.resolve(path: ["s"], key: "q"), .unknown)
    }

    func testResolveUnknownOnCommandPath() {
        // Can't descend past a leaf command.
        XCTAssertEqual(LeaderMenu.resolve(path: ["n"], key: "x"), .unknown)
    }

    // MARK: - integration with the state machine (drill-down + back)

    func testDrillDownThenFire() {
        let c = KeyboardModeController()
        c.openLeader()
        XCTAssertEqual(LeaderMenu.resolve(path: c.leaderPath!, key: "s"), .descend)
        c.descendLeader("s")
        XCTAssertEqual(LeaderMenu.resolve(path: c.leaderPath!, key: "v"), .fire(.splitVertical))
        c.closeLeader()
        XCTAssertNil(c.leaderPath)
    }

    func testBackFromSubmenuReturnsToRootEntries() {
        let c = KeyboardModeController()
        c.openLeader()
        c.descendLeader("g")
        XCTAssertEqual(LeaderMenu.entries(at: c.leaderPath!).map(\.key), ["w", "0", "b"])
        c.leaderBack()   // back to root
        XCTAssertEqual(LeaderMenu.entries(at: c.leaderPath!).map(\.key),
                       ["s", "n", "d", "g", "w", "c", "f", "/", "?"])
    }
}
