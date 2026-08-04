import XCTest
import AppKit
@testable import seahelm

/// Measures the ⌘B collapse instead of trusting that scheduling an animation
/// means one runs: samples the sidebar's real width mid-flight and asserts it is
/// somewhere between the two endpoints.
final class ChromeCollapseAnimationTests: XCTestCase {

    private var window: NSWindow!
    private var chrome: WindowChromeController!

    override func setUp() {
        super.setUp()
        chrome = WindowChromeController()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.contentViewController = chrome
        window.layoutIfNeeded()
        // The very first animated collapse in a process pays ~200ms of Core
        // Animation / vibrancy warm-up on the main thread, which starves the
        // frames a measurement needs. Burn that cost here, not in a test body.
        apply(collapsed: true, animated: true)
        spin(0.5)
    }

    override func tearDown() {
        window.contentViewController = nil
        window = nil
        chrome = nil
        super.tearDown()
    }

    private var sidebar: NSView {
        find(in: chrome.view, id: "chrome.sidebarColumn")!
    }

    /// `clampWidth` floors at `minSidebarWidth` when the host window is too
    /// narrow, so the resting width is derived, not the 300 that was requested.
    private var expandedWidth: CGFloat {
        ChromeLayoutMetrics.clampWidth(300, windowWidth: chrome.view.bounds.width)
    }

    private func find(in view: NSView, id: String) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews {
            if let hit = find(in: sub, id: id) { return hit }
        }
        return nil
    }

    private func apply(collapsed: Bool, animated: Bool) {
        chrome.applyState(
            ChromeLayoutState(width: 300, collapsed: collapsed, activePane: .firstMate),
            animated: animated
        )
    }

    /// Spin the main run loop for `seconds` so animations actually advance.
    private func spin(_ seconds: TimeInterval) {
        let done = expectation(description: "spin \(seconds)")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2)
    }

    func testUnanimatedCollapseIsImmediate() {
        apply(collapsed: false, animated: false)
        XCTAssertEqual(sidebar.frame.width, expandedWidth, accuracy: 0.5)

        apply(collapsed: true, animated: false)
        XCTAssertEqual(sidebar.frame.width, 0, accuracy: 0.5)
    }

    func testAnimatedCollapseIsInFlightPartWayThrough() {
        apply(collapsed: false, animated: false)
        XCTAssertEqual(sidebar.frame.width, expandedWidth, accuracy: 0.5)

        apply(collapsed: true, animated: true)

        // Sample repeatedly rather than once at the midpoint. A single
        // `spin(duration / 2)` only holds if the run loop wakes near that
        // instant; under load it overshoots the whole 0.24s animation, the
        // sidebar reads 0, and the test fails claiming it "snapped shut" when
        // it had merely finished. Polling asks the real question — did the
        // width ever pass through an intermediate value — instead of betting
        // on one wake-up landing in the window.
        let duration = ChromeLayoutMetrics.collapseAnimationDuration
        var sawIntermediate = false
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            let w = sidebar.frame.width
            if w > 0, w < expandedWidth {
                sawIntermediate = true
                break
            }
            spin(duration / 20)
        }

        XCTAssertTrue(sawIntermediate, "sidebar snapped shut instead of animating")
    }

    func testAnimatedCollapseSettlesClosed() {
        apply(collapsed: false, animated: false)
        apply(collapsed: true, animated: true)
        spin(ChromeLayoutMetrics.collapseAnimationDuration + 0.25)

        XCTAssertEqual(sidebar.frame.width, 0, accuracy: 0.5)
        XCTAssertTrue(sidebar.isHidden)
    }

    func testAnimatedExpandIsInFlightPartWayThrough() {
        apply(collapsed: true, animated: false)
        XCTAssertEqual(sidebar.frame.width, 0, accuracy: 0.5)

        apply(collapsed: false, animated: true)
        spin(ChromeLayoutMetrics.collapseAnimationDuration / 2)

        let mid = sidebar.frame.width
        XCTAssertGreaterThan(mid, 0, "sidebar had not started moving")
        XCTAssertLessThan(mid, expandedWidth,"sidebar snapped open instead of animating")
    }

    /// `MainWindowController.applyChromeState` does not stop at `applyState`: it
    /// synchronously repositions the traffic lights, which calls
    /// `layoutSubtreeIfNeeded()` on a view inside this same window. That forced
    /// layout is the thing to watch — if it resolves the width constraint to its
    /// final value, the slide is over before the first frame is drawn and ⌘B
    /// looks instant no matter what the animation block asked for.
    func testForcedLayoutRightAfterApplyDoesNotSnapTheSlide() {
        apply(collapsed: false, animated: false)

        apply(collapsed: true, animated: true)
        // Stand-in for positionStandardWindowButtons()'s host.layoutSubtreeIfNeeded().
        find(in: chrome.view, id: "chrome.terminalHeader")?.layoutSubtreeIfNeeded()

        spin(ChromeLayoutMetrics.collapseAnimationDuration / 2)
        let mid = sidebar.frame.width
        XCTAssertGreaterThan(mid, 0, "a forced layout right after apply snapped the sidebar shut")
        XCTAssertLessThan(mid, expandedWidth, "sidebar had not started moving")
    }

    func testAnimatedExpandSettlesOpen() {
        apply(collapsed: true, animated: false)
        apply(collapsed: false, animated: true)
        spin(ChromeLayoutMetrics.collapseAnimationDuration + 0.25)

        XCTAssertEqual(sidebar.frame.width, expandedWidth, accuracy: 0.5)
        XCTAssertFalse(sidebar.isHidden)
        XCTAssertEqual(sidebar.alphaValue, 1, accuracy: 0.01)
    }
}

