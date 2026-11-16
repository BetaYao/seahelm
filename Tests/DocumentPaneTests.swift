import XCTest
@testable import seahelm

/// The document pane is a pane of the split tree, not a terminal: it splits
/// off the focused pane like ⌘D, is never saved or mirrored, and never counts
/// as a terminal.
final class DocumentPaneTests: XCTestCase {
    private func tree() -> SplitTree {
        SplitTree(worktreePath: "/w", rootLeafId: "t1", stationId: "s1", paneSessionKey: "seahelm-w")
    }

    func testInsertSplitsTheFocusedPaneAndTakesFocus() throws {
        let t = tree()
        let doc = t.insertDocument()
        XCTAssertEqual(t.documentId, doc)
        XCTAssertEqual(t.focusedId, doc)
        XCTAssertTrue(t.documentFocused)
        XCTAssertEqual(t.paneIds, ["t1", doc], "beside the terminal, to its right")
        guard case .split(_, let axis, _, _, _) = t.root else { return XCTFail("not split") }
        XCTAssertEqual(axis, .horizontal, "side by side, as ⌘D")
        XCTAssertEqual(t.insertDocument(), doc, "one per tree: a second insert reuses it")
    }

    func testDocumentIsNoTerminal() {
        let t = tree()
        let doc = t.insertDocument()
        XCTAssertEqual(t.leafCount, 1, "terminals only")
        XCTAssertEqual(t.allLeaves.map(\.id), ["t1"])
        XCTAssertNil(t.root.findLeaf(id: doc))
        XCTAssertNil(t.removeLeaf(id: "t1"), "the last terminal stays, even beside a document")
    }

    func testSavedAndMirroredLayoutsLeaveItOut() {
        let t = tree()
        t.insertDocument()
        guard case .leaf(let key, _) = t.toCodable() else { return XCTFail("document was saved") }
        XCTAssertEqual(key, "seahelm-w")

        t.focusedId = "t1"
        t.splitFocusedLeaf(axis: .vertical, newLeafId: "t2", newStationId: "s2", newSessionName: "seahelm-w--pane-1")
        XCTAssertEqual(t.toCodable().paneSessionKeys, ["seahelm-w", "seahelm-w--pane-1"])
    }

    func testSplittingTheDocumentPaneAddsATerminalBesideIt() {
        let t = tree()
        let doc = t.insertDocument()
        t.splitFocusedLeaf(axis: .vertical, newLeafId: "t2", newStationId: "s2", newSessionName: "k2")
        XCTAssertEqual(t.paneIds, ["t1", doc, "t2"])
        XCTAssertEqual(t.focusedId, "t2")
        XCTAssertEqual(t.documentId, doc)
    }

    func testRemoveGivesTheSpaceAndFocusBack() {
        let t = tree()
        t.insertDocument()
        t.removeDocument()
        XCTAssertNil(t.documentId)
        XCTAssertEqual(t.focusedId, "t1")
        XCTAssertEqual(t.paneIds, ["t1"])
    }

    func testFramesIncludeTheDocumentPane() throws {
        let t = tree()
        let doc = t.insertDocument()
        let frames = SplitContainerView.computeFrames(node: t.root, in: CGRect(x: 0, y: 0, width: 801, height: 400))
        let left = try XCTUnwrap(frames["t1"])
        let right = try XCTUnwrap(frames[doc])
        XCTAssertEqual(left.width, right.width, accuracy: 1)
        XCTAssertGreaterThan(right.minX, left.maxX)
    }

    // MARK: - Tabs

    func testTabsReuseAndCloseLeavesTheRightOneOnScreen() {
        let pane = DocumentPaneView()
        var emptied = false
        pane.onEmpty = { emptied = true }
        let a = DocumentPaneView.Item.change(worktreePath: "/w", path: "a.swift")
        let b = DocumentPaneView.Item.change(worktreePath: "/w", path: "b.swift")
        let c = DocumentPaneView.Item.change(worktreePath: "/w", path: "c.swift")
        pane.open(a); pane.open(b); pane.open(c)
        pane.open(a)
        XCTAssertEqual(pane.itemsForTesting, [a, b, c], "reopening selects, not duplicates")
        XCTAssertEqual(pane.activeItemForTesting, a)
        XCTAssertEqual(pane.title, "Δ a.swift")

        pane.select(c.key)
        pane.close(c.key)
        XCTAssertEqual(pane.activeItemForTesting, b, "closing the active tab shows its left neighbour")
        pane.close(a.key)
        XCTAssertEqual(pane.activeItemForTesting, b, "closing another keeps the active one")
        XCTAssertFalse(emptied)
        pane.closeActive()
        XCTAssertTrue(emptied, "the last tab empties the pane")
    }

    func testFileAndChangeOfOnePathAreTwoTabs() {
        XCTAssertNotEqual(DocumentPaneView.Item.file(path: "/w/a.swift").key,
                          DocumentPaneView.Item.change(worktreePath: "/w", path: "/w/a.swift").key)
        XCTAssertEqual(DocumentPaneView.Item.file(path: "/w/src/a.swift").title, "a.swift")
    }
}
