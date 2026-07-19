import XCTest
@testable import seahelm

/// Structural split must not SIGWINCH existing panes (fancy prompts redraw).
final class PtyGridAbsorbTests: XCTestCase {

    func testAbsorbFreezesPtyResizeAcrossDeferredFlush() {
        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.markSurfaceSizeSynced(NSSize(width: 800, height: 600))

        // Simulate split: AppKit frame shrinks, then absorb.
        view.setFrameSize(NSSize(width: 400, height: 600))
        view.absorbBoundsWithoutPtyResize()

        XCTAssertTrue(view.freezePtyGridResizeForTesting)
        XCTAssertTrue(view.pendingPtyGridSyncForTesting)
        XCTAssertEqual(view.lastSyncedSizeForTesting, NSSize(width: 400, height: 600))

        // endLiveResize-style flush must not clear the freeze / force set_size.
        view.flushDeferredSurfaceSize(pinHeight: false)
        XCTAssertTrue(view.freezePtyGridResizeForTesting)
        XCTAssertTrue(view.pendingPtyGridSyncForTesting)

        // A follow-up setFrame (layout pass) must also stay frozen.
        view.setFrameSize(NSSize(width: 390, height: 600))
        XCTAssertTrue(view.freezePtyGridResizeForTesting)
        XCTAssertEqual(view.lastSyncedSizeForTesting, NSSize(width: 390, height: 600))
    }

    func testFocusDoesNotFlushAbsorbedGrid() {
        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        view.markSurfaceSizeSynced(NSSize(width: 800, height: 600))
        view.absorbBoundsWithoutPtyResize()

        _ = view.becomeFirstResponder()

        XCTAssertTrue(view.freezePtyGridResizeForTesting,
                      "Focus alone must not unfreeze — that would SIGWINCH on click-back")
        XCTAssertTrue(view.pendingPtyGridSyncForTesting)
    }

    func testKeyDownFlushesAbsorbedGrid() {
        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        view.markSurfaceSizeSynced(NSSize(width: 800, height: 600))
        view.absorbBoundsWithoutPtyResize()
        XCTAssertTrue(view.freezePtyGridResizeForTesting)

        let flushed = view.flushPendingPtyGridSyncIfNeeded()
        XCTAssertTrue(flushed)
        XCTAssertFalse(view.freezePtyGridResizeForTesting)
        XCTAssertFalse(view.pendingPtyGridSyncForTesting)
    }

    func testClearFreezeAllowsExplicitSync() {
        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        view.absorbBoundsWithoutPtyResize()
        XCTAssertTrue(view.freezePtyGridResizeForTesting)

        view.clearPtyGridResizeFreeze()
        XCTAssertFalse(view.freezePtyGridResizeForTesting)
        XCTAssertFalse(view.pendingPtyGridSyncForTesting)
    }
}
