import AppKit
import XCTest
@testable import seahelm

final class MenuBuilderTests: XCTestCase {
    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    func testTopLevelMenus() {
        let menu = MenuBuilder.buildMainMenu()
        XCTAssertEqual(menu.items.compactMap { $0.submenu?.title },
                       ["Seahelm", "File", "Edit", "View", "Pane", "Fleet", "Window", "Help"])
    }

    /// Every item does something that exists: an action the window controller,
    /// the app, the window or the text system answers.
    func testEveryActionExists() {
        let answerers: [AnyClass] = [MainWindowController.self, NSApplication.self, NSWindow.self, NSTextView.self]
        for item in allItems(MenuBuilder.buildMainMenu()) {
            guard item.submenu == nil, let action = item.action else { continue }
            XCTAssertTrue(answerers.contains { $0.instancesRespond(to: action) },
                          "\(item.title): nothing answers \(action)")
        }
    }

    /// The command language was cut to /new, /status, /go, /show, /help; the
    /// old verbs' items (and the keys they held) are gone.
    func testNoRetiredCommands() {
        let titles = allItems(MenuBuilder.buildMainMenu()).map(\.title)
        for retired in ["/order", "/broadcast", "/return", "/add", "/feedback"] {
            XCTAssertFalse(titles.contains { $0.contains(retired) }, retired)
        }
    }

    /// No key chord is claimed twice.
    func testNoDuplicateShortcuts() {
        var seen: [String: String] = [:]
        for item in allItems(MenuBuilder.buildMainMenu()) where !item.keyEquivalent.isEmpty {
            let chord = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent)"
            XCTAssertNil(seen[chord], "\(item.title) and \(seen[chord] ?? "") share a shortcut")
            seen[chord] = item.title
        }
    }

    /// The UI smoke test opens pairing by this exact title.
    func testPairingKeepsItsTitle() {
        XCTAssertTrue(allItems(MenuBuilder.buildMainMenu()).contains { $0.title == "Pair Remote Clients..." })
    }
}
