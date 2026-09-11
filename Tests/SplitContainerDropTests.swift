import XCTest
@testable import seahelm

/// Drop targeting in a split: the pane under the cursor takes the drop and wears
/// the highlight, whichever pane holds focus.
final class SplitContainerDropTests: XCTestCase {

    // MARK: - Resolver

    /// A 400pt-wide horizontal split: 199pt pane, 1pt seam, 200pt pane.
    private let frames: [String: CGRect] = [
        "A": CGRect(x: 0, y: 0, width: 199, height: 300),
        "B": CGRect(x: 200, y: 0, width: 200, height: 300),
    ]

    func testPointInsideAPaneTargetsThatPane() {
        XCTAssertEqual(SplitContainerView.dropTargetStationId(at: CGPoint(x: 50, y: 100), paneFrames: frames), "A")
        XCTAssertEqual(SplitContainerView.dropTargetStationId(at: CGPoint(x: 350, y: 100), paneFrames: frames), "B")
    }

    func testSeamBetweenPanesTargetsTheNearestPane() {
        XCTAssertEqual(SplitContainerView.dropTargetStationId(at: CGPoint(x: 199.2, y: 100), paneFrames: frames), "A")
        XCTAssertEqual(SplitContainerView.dropTargetStationId(at: CGPoint(x: 199.8, y: 100), paneFrames: frames), "B")
    }

    func testPointFarFromEveryPaneTargetsNothing() {
        XCTAssertNil(SplitContainerView.dropTargetStationId(at: CGPoint(x: 500, y: 100), paneFrames: frames))
        XCTAssertNil(SplitContainerView.dropTargetStationId(at: CGPoint(x: 50, y: 100), paneFrames: [:]))
    }

    // MARK: - Container

    /// A two-pane horizontal split of surfaceless terminal views.
    private func makeSplit() -> (split: SplitContainerView, left: GhosttyNSView, right: GhosttyNSView) {
        let split = SplitContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let tree = SplitTree(worktreePath: "/wt", rootLeafId: "leafA", stationId: "sA", paneSessionKey: "")
        tree.splitFocusedLeaf(axis: .horizontal, newLeafId: "leafB", newStationId: "sB", newSessionName: "")
        let left = GhosttyNSView(frame: .zero)
        let right = GhosttyNSView(frame: .zero)
        split.surfaceViews = ["sA": left, "sB": right]
        split.tree = tree   // didSet → layoutTree()
        return (split, left, right)
    }

    func testSetDropTargetHighlightsExactlyThatPane() {
        let (split, left, right) = makeSplit()
        split.setDropTarget("sB")
        XCTAssertFalse(left.showsDropHighlight)
        XCTAssertTrue(right.showsDropHighlight)
        XCTAssertEqual(split.highlightedDropStationId, "sB")
    }

    func testMovingTheDropTargetClearsThePreviousPane() {
        let (split, left, right) = makeSplit()
        split.setDropTarget("sB")
        split.setDropTarget("sA")
        XCTAssertTrue(left.showsDropHighlight)
        XCTAssertFalse(right.showsDropHighlight)
    }

    func testClearingTheDropTargetClearsEveryPane() {
        let (split, left, right) = makeSplit()
        split.setDropTarget("sA")
        split.setDropTarget(nil)
        XCTAssertFalse(left.showsDropHighlight)
        XCTAssertFalse(right.showsDropHighlight)
        XCTAssertNil(split.highlightedDropStationId)
    }

    /// A re-embed mid-drag strips the highlight (removeFromSuperview); the next
    /// drag update for the same pane must put it back.
    func testReembeddedPaneRegainsHighlightOnNextUpdate() {
        let (split, left, _) = makeSplit()
        split.setDropTarget("sA")
        left.removeFromSuperview()
        XCTAssertFalse(left.showsDropHighlight)
        split.addSubview(left)
        split.setDropTarget("sA")
        XCTAssertTrue(left.showsDropHighlight)
    }

    func testBothPanesOfASplitAreDropTargets() {
        let (split, _, _) = makeSplit()
        let visible = split.visiblePaneFrames()
        XCTAssertEqual(Set(visible.keys), ["sA", "sB"])
        XCTAssertEqual(SplitContainerView.dropTargetStationId(at: CGPoint(x: 350, y: 100), paneFrames: visible), "sB")
        XCTAssertEqual(SplitContainerView.dropTargetStationId(at: CGPoint(x: 50, y: 100), paneFrames: visible), "sA")
    }

    func testZoomedOutPaneIsNeverADropTarget() {
        let (split, _, _) = makeSplit()
        split.setZoom(leafId: "leafA", on: true)
        let visible = split.visiblePaneFrames()
        XCTAssertEqual(Set(visible.keys), ["sA"])
        XCTAssertEqual(SplitContainerView.dropTargetStationId(at: CGPoint(x: 350, y: 100), paneFrames: visible), "sA")
    }
}
