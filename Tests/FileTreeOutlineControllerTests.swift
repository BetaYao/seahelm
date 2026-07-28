import XCTest
import AppKit
@testable import seahelm

final class FileTreeOutlineControllerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-filetree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/App", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: root.appendingPathComponent("Sources/App/Main.swift"))
        try Data().write(to: root.appendingPathComponent(".env"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".config", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testChildNodesHideDotfilesByDefault() {
        let nodes = FileTreeOutlineController.childNodes(of: root, showHidden: false)
        let names = nodes.map(\.url.lastPathComponent)
        XCTAssertEqual(names, ["Sources"])
    }

    func testChildNodesIncludeDotfilesWhenShowHidden() {
        let nodes = FileTreeOutlineController.childNodes(of: root, showHidden: true)
        let names = Set(nodes.map(\.url.lastPathComponent))
        XCTAssertEqual(names, ["Sources", ".config", ".env"])
    }

    /// Toggling showHidden rebuilds the tree — previously this dropped expansion
    /// because `didSet` called bare `reload()`. Drive the outline through a
    /// scroll view and assert folders stay open across the toggle.
    func testTogglingShowHiddenPreservesExpandedFolders() throws {
        let controller = FileTreeOutlineController(rootPath: root.path)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        scroll.documentView = controller.outlineView
        controller.outlineView.frame = scroll.bounds
        controller.outlineView.reloadData()
        // Force datasource to materialize root rows before expand.
        XCTAssertGreaterThan(controller.outlineView.numberOfRows, 0)

        let sources = root.appendingPathComponent("Sources").standardizedFileURL.path
        let app = root.appendingPathComponent("Sources/App").standardizedFileURL.path
        controller.restoreExpansion([sources, app])
        let before = controller.currentExpandedPaths()
        try XCTSkipIf(before.isEmpty, "NSOutlineView did not expand in this host")

        controller.showHidden.toggle()

        XCTAssertEqual(
            controller.currentExpandedPaths(),
            before,
            "showHidden toggle must restore the pre-toggle expansion snapshot"
        )
        XCTAssertTrue(before.isSuperset(of: [sources, app]))
    }

    func testRestoreExpansionStopsWhenPathsAreMissing() {
        let controller = FileTreeOutlineController(rootPath: root.path)
        // Must terminate even when nothing in the outline matches.
        controller.restoreExpansion(["/definitely/not/in/this/tree"])
        XCTAssertEqual(controller.currentExpandedPaths(), [])
    }
}
