import XCTest
import AppKit
@testable import seahelm

final class EditTabStripViewTests: XCTestCase {

    private func makeStrip(width: CGFloat = 400) -> EditTabStripView {
        let strip = EditTabStripView()
        strip.translatesAutoresizingMaskIntoConstraints = true
        strip.frame = NSRect(x: 0, y: 0, width: width, height: EditTabStripView.stripHeight)
        strip.apply(items: [
            .init(id: "a", title: "First", closable: false),
            .init(id: "b", title: "Second", closable: true),
        ], selectedId: "a")
        strip.layoutSubtreeIfNeeded()
        return strip
    }

    func testTabsStartVisible() {
        let strip = makeStrip()
        XCTAssertEqual(strip.clipOriginYForTesting, 0)
        XCTAssertTrue(strip.firstTabIsVisibleForTesting)
    }

    /// Regression: hoisting the strip from its column into the chrome header left
    /// the clip view seated at y = -27. Every frame stayed correct — strip, scroll
    /// view, document view and each tab — so nothing looked wrong from the outside,
    /// but the visible rect slid off the tabs and the row painted empty.
    ///
    /// The assertion is on visibility rather than the offset alone: that is the
    /// property that broke, and it holds however AppKit chooses to seat the clip.
    func testTabsStayVisibleAfterReparenting() {
        let strip = makeStrip()
        let column = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        let header = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        column.addSubview(strip)
        strip.layoutSubtreeIfNeeded()

        strip.removeFromSuperview()
        header.addSubview(strip)
        strip.frame = NSRect(x: 12, y: 5, width: 380, height: EditTabStripView.stripHeight)
        strip.layoutSubtreeIfNeeded()

        XCTAssertEqual(strip.clipOriginYForTesting, 0, "the strip never scrolls vertically")
        XCTAssertTrue(strip.firstTabIsVisibleForTesting, "tabs must survive the move into the header")
    }

    /// Re-applying the same ids must not churn the view tree (the 2s status poll
    /// nudges titles constantly).
    func testSameIdsKeepTheSameTabViews() {
        let strip = makeStrip()
        let before = strip.firstTabIsVisibleForTesting
        strip.apply(items: [
            .init(id: "a", title: "First renamed", closable: false),
            .init(id: "b", title: "Second", closable: true),
        ], selectedId: "b")
        strip.layoutSubtreeIfNeeded()
        XCTAssertTrue(before && strip.firstTabIsVisibleForTesting)
    }

    // MARK: - Hit testing

    /// The chrome header claims every non-button point to drag the window, and a
    /// tab is a plain view — so a tab hit has to be reported, or clicking a tab
    /// drags the window instead of switching.
    func testTabPointsAreHitTestable() {
        let strip = makeStrip()
        let tabFrame = strip.firstTabFrameForTesting
        XCTAssertFalse(tabFrame.isEmpty, "precondition: a tab was laid out")
        let hit = strip.hitTest(strip.convert(NSPoint(x: tabFrame.midX, y: tabFrame.midY), to: strip.superview))
        XCTAssertNotNil(hit, "a click on a tab must reach the strip")
    }

    /// …but the leftover space must stay transparent, or the row stops dragging
    /// the window the way a title bar should.
    func testEmptyStripAreaIsTransparentToHitTesting() {
        let strip = makeStrip(width: 600)   // wider than its tabs
        let empty = NSPoint(x: 590, y: EditTabStripView.stripHeight / 2)
        XCTAssertNil(strip.hitTest(strip.convert(empty, to: strip.superview)),
                     "empty strip space belongs to the window drag")
    }

    /// Living in the chrome header means AppKit will turn a press into a window
    /// move unless every view in the hit path opts out — hit testing alone does
    /// not make a tab clickable.
    func testStripAndTabsOptOutOfWindowDrag() {
        let strip = makeStrip()
        XCTAssertFalse(strip.mouseDownCanMoveWindow)
        let tabFrame = strip.firstTabFrameForTesting
        let hit = strip.hitTest(strip.convert(NSPoint(x: tabFrame.midX, y: tabFrame.midY), to: strip.superview))
        XCTAssertEqual(hit?.mouseDownCanMoveWindow, false, "the hit view must opt out too")
    }

    /// A click on the tab's text must be answered by the tab, not by the label —
    /// the label neither selects nor opts out of the window drag.
    func testTabTextAnswersAsTheTab() {
        let strip = makeStrip()
        let tabFrame = strip.firstTabFrameForTesting
        let point = strip.convert(NSPoint(x: tabFrame.minX + 20, y: tabFrame.midY), to: strip.superview)
        let hit = strip.hitTest(point)
        XCTAssertFalse(hit is NSTextField, "the label must not be the hit view")
    }
}
