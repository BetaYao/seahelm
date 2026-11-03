import XCTest
import AppKit
@testable import seahelm

/// Records ratios and, like the real container, moves the divider to follow.
private final class FollowingDelegate: DividerDelegate {
    weak var divider: DividerView?
    let size: CGFloat
    var ratios: [CGFloat] = []
    init(size: CGFloat) { self.size = size }
    func dividerDidBeginDrag(_ splitNodeId: String) {}
    func dividerDidMove(_ splitNodeId: String, newRatio: CGFloat) {
        ratios.append(newRatio)
        guard let divider else { return }
        divider.frame.origin.x = newRatio * size - divider.frame.width / 2
    }
    func dividerDidEndDrag(_ splitNodeId: String) {}
    func dividerDidDoubleClick(_ splitNodeId: String) {}
}

final class SplitDividerDragTests: XCTestCase {
    private func mouse(_ type: NSEvent.EventType, x: CGFloat, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 100), modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// The divider moves under the drag. Measuring against its own (moving) frame
    /// fed each step back into the next and the seam shook; the ratio must follow
    /// the pointer alone.
    func testRatioFollowsThePointerWhileTheDividerMoves() {
        let size: CGFloat = 800
        let host = NSView(frame: NSRect(x: 0, y: 0, width: size, height: 600))
        let divider = DividerView(splitNodeId: "s", axis: .horizontal)
        divider.frame = NSRect(x: 392, y: 0, width: 16, height: 600)
        divider.parentSplitSize = size
        divider.currentRatio = 0.5
        host.addSubview(divider)
        let delegate = FollowingDelegate(size: size)
        delegate.divider = divider
        divider.delegate = delegate

        divider.mouseDown(with: mouse(.leftMouseDown, x: 400))
        for x in stride(from: 410, through: 480, by: 10) {
            divider.mouseDragged(with: mouse(.leftMouseDragged, x: CGFloat(x)))
        }
        divider.mouseUp(with: mouse(.leftMouseUp, x: 480))

        let expected = stride(from: 410, through: 480, by: 10).map { 0.5 + (CGFloat($0) - 400) / size }
        XCTAssertEqual(delegate.ratios.count, expected.count)
        for (got, want) in zip(delegate.ratios, expected) {
            XCTAssertEqual(got, want, accuracy: 0.0001)
        }
    }

    /// A pane re-added on top of the divider must not take the click inside the
    /// grip — the divider lights up there, so it has to drag there.
    func testTheGripWinsOverAPaneOnTop() {
        let container = SplitContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let tree = SplitTree(worktreePath: "/wt", rootLeafId: "a", stationId: "station-a", paneSessionKey: "k-a")
        tree.splitFocusedLeaf(axis: .horizontal, newLeafId: "b", newStationId: "station-b", newSessionName: "k-b")
        container.tree = tree
        let divider = container.subviews.compactMap { $0 as? DividerView }.first
        XCTAssertNotNil(divider, "the split laid out a divider")
        let pane = NSView(frame: container.bounds)
        container.addSubview(pane)   // above the divider, as a re-embedded pane is

        let host = NSView(frame: container.frame)
        host.addSubview(container)
        let seam = divider!.frame.midX
        XCTAssertTrue(container.hitTest(NSPoint(x: seam + 6, y: 300)) === divider, "inside the grip, beside the seam")
        XCTAssertTrue(container.hitTest(NSPoint(x: 100, y: 300)) === pane, "elsewhere the pane still gets its clicks")
    }
}
