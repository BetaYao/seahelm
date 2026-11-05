import XCTest
@testable import seahelm

/// Going full screen (or the zoom button) resizes the window without a live
/// drag, so nothing used to lift the sidebar-drag suppression: every terminal
/// kept its old grid inside a larger pane.
final class WindowResizeResyncTests: XCTestCase {
    func testResyncAfterWindowResizeLiftsTheSidebarDragSuppression() {
        let bridge = GhosttyBridge.shared
        // A sidebar drag: pinHeight, which leaves the grid suppressed after it.
        bridge.beginLiveResize(pinHeight: true)
        bridge.endLiveResize()
        XCTAssertTrue(bridge.suppressSurfaceGridResize)

        bridge.resyncAfterWindowResize()

        XCTAssertFalse(bridge.suppressSurfaceGridResize, "the terminals could not follow the window")
        XCTAssertFalse(bridge.isLiveResizing)
    }
}
