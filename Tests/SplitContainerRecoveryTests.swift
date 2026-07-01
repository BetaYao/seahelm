import XCTest
@testable import seahelm

/// Regression tests for zmx session-recovery re-embed. The bug: `Station.delegate`
/// was never assigned, so `stationDidRecover` was dead code and a recovered
/// (recreated) surface was orphaned — a dead pane until Cmd+W. `layoutTree()` now
/// wires the delegate to the displaying container, and `stationDidRecover`
/// re-registers the new view.
final class SplitContainerRecoveryTests: XCTestCase {

    /// The actual bug: laying out a tree must wire each station's delegate to the
    /// container so recovery has somewhere to call back to.
    func testLayoutTreeWiresStationDelegate() {
        let split = SplitContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let station = Station()
        StationRegistry.shared.register(station)
        defer { StationRegistry.shared.unregister(station.id) }

        let tree = SplitTree(worktreePath: "/wt", rootLeafId: "leaf1",
                             stationId: station.id, sessionName: "")
        split.surfaceViews[station.id] = NSView()
        split.tree = tree   // didSet → layoutTree()

        XCTAssertTrue(station.delegate === split,
                      "layoutTree must wire the station delegate to the displaying container")
    }

    /// After recovery, the container must display the NEW view for that leaf,
    /// reparented into the container so input reaches the live surface.
    func testReembedRecoveredViewReparentsAndReregisters() {
        let split = SplitContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let tree = SplitTree(worktreePath: "/wt", rootLeafId: "leaf1",
                             stationId: "s1", sessionName: "")
        let oldView = NSView()
        split.surfaceViews["s1"] = oldView
        split.tree = tree   // reparents oldView into split
        XCTAssertTrue(oldView.superview === split)

        let newView = NSView()
        split.reembedRecoveredView(stationId: "s1", view: newView)

        XCTAssertTrue(split.surfaceViews["s1"] === newView,
                      "recovered view must replace the old one for its station")
        XCTAssertTrue(newView.superview === split,
                      "recovered view must be reparented into the container")
    }
}
