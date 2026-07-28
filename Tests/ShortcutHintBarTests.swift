import XCTest
@testable import seahelm

/// The strip replaced the fleet column's composer, so its whole job is to cost
/// as little vertical space as possible while staying readable. These pin the
/// height budget and the narrow-sidebar wrap.
final class ShortcutHintBarTests: XCTestCase {

    /// Host the bar the way the fleet column does. Returns both so a test can
    /// resize the host and re-lay out, mimicking a sidebar drag.
    private func hosted(width: CGFloat) -> (bar: ShortcutHintBar, host: NSView) {
        let bar = ShortcutHintBar()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        return (bar, host)
    }

    private func laidOut(width: CGFloat) -> ShortcutHintBar {
        hosted(width: width).bar
    }

    private func resize(_ host: NSView, to width: CGFloat) {
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        host.layoutSubtreeIfNeeded()
    }

    func testFitsInTwoLinesAtSidebarWidth() {
        let bar = laidOut(width: 300)
        XCTAssertEqual(bar.pairsPerRowForTesting, 3)
        XCTAssertEqual(bar.rowCountForTesting, 2)
    }

    /// The three-row version this replaced ran ~87pt. Two lines has to stay well
    /// under that or the strip is not worth its space.
    func testHeightStaysWithinBudget() {
        let bar = laidOut(width: 300)
        XCTAssertLessThanOrEqual(bar.frame.height, 62,
                                 "shortcut strip grew past its vertical budget")
        XCTAssertGreaterThan(bar.frame.height, 30, "strip collapsed — rows missing?")
    }

    /// Dragged narrow, it wraps to two pairs per line rather than clipping the
    /// third pair off the edge.
    func testWrapsToTwoPairsWhenNarrow() {
        let bar = laidOut(width: 170)
        XCTAssertEqual(bar.pairsPerRowForTesting, 2)
        XCTAssertEqual(bar.rowCountForTesting, 3)
    }

    /// Dragging the sidebar re-wraps the strip. `NSGridView.removeRow(at:)` keeps
    /// the old cells parented to the grid, so without an explicit detach every
    /// past layout stays on screen, stacked on the current one.
    func testRewrapDoesNotLeaveGhostedRowsBehind() {
        let (bar, host) = hosted(width: 300)
        let pairs = 6
        XCTAssertEqual(bar.contentViewCountForTesting, pairs * 2)

        resize(host, to: 170)          // 3-per-line → 2-per-line
        XCTAssertEqual(bar.pairsPerRowForTesting, 2)
        XCTAssertEqual(bar.contentViewCountForTesting, pairs * 2,
                       "stale cells from the previous wrap are still in the view tree")

        resize(host, to: 300)          // and back
        XCTAssertEqual(bar.pairsPerRowForTesting, 3)
        XCTAssertEqual(bar.contentViewCountForTesting, pairs * 2,
                       "stale cells from the previous wrap are still in the view tree")
    }

    /// A drag that parks right on the wrap threshold must settle, not oscillate.
    func testWrapThresholdHasHysteresis() {
        let (bar, host) = hosted(width: 300)
        let boundary = bar.wideFittingWidthForTesting + 30   // exactly enough for 3
        resize(host, to: boundary)
        XCTAssertEqual(bar.pairsPerRowForTesting, 3)
        resize(host, to: boundary - 1)
        XCTAssertEqual(bar.pairsPerRowForTesting, 2)
        // Back to exactly the boundary: hysteresis keeps it at 2 until there is
        // real headroom, so a jittering drag can't flap it every frame.
        resize(host, to: boundary)
        XCTAssertEqual(bar.pairsPerRowForTesting, 2)
        resize(host, to: boundary + 8)
        XCTAssertEqual(bar.pairsPerRowForTesting, 3)
    }
}
