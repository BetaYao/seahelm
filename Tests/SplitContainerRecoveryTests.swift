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
                             stationId: station.id, paneSessionKey: "")
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
                             stationId: "s1", paneSessionKey: "")
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

    /// `Station.sleepContainer` is weak, so a pane that stays asleep across a
    /// layout rebuild loses it and `wake()` used to bail — stranding the pane
    /// with no surface and no way back. The displaying container is the
    /// substitute, since leaf views are added to it anyway.
    func testContainerOffersItselfAsWakeFallback() {
        let split = SplitContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let station = Station()

        XCTAssertTrue(split.stationContainer(for: station) === split,
                      "the displaying container must offer itself for a woken station")
    }

    /// Delegates that do not display panes keep the no-op default, so the
    /// fallback stays opt-in rather than resurrecting a pane into a random view.
    func testDelegateFallbackDefaultsToNil() {
        final class BareDelegate: StationDelegate {
            func stationDidRecover(_ station: Station) {}
        }

        XCTAssertNil(BareDelegate().stationContainer(for: Station()),
                     "the protocol default must not invent a container")
    }

    /// Laying out an asleep leaf must wire the station delegate even though
    /// there is no surfaceViews entry — otherwise Wake has no container once
    /// the weak sleepContainer goes stale.
    func testLayoutAsleepViewsWiresStationDelegate() {
        let split = SplitContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let station = Station()
        StationRegistry.shared.register(station)
        defer { StationRegistry.shared.unregister(station.id) }

        // Post-sleep state without needing a live Ghostty surface.
        station.adoptAsleepStateForTesting()

        let tree = SplitTree(worktreePath: "/wt", rootLeafId: "leaf1",
                             stationId: station.id, paneSessionKey: "seahelm-wt-1")
        split.tree = tree   // didSet → layoutTree() → layoutAsleepViews

        XCTAssertTrue(station.delegate === split,
                      "asleep layout must wire the station delegate for Wake fallback")
    }
}

// MARK: - Sleep / Wake plan (embed + Wake button)

final class StationSleepWakePlanTests: XCTestCase {

    /// The exact bug behind "Wake does nothing": returning to a worktree saw
    /// `surface == nil`, called `create`, left `isAsleep` set, and `wake()`
    /// then required `surface == nil` — a permanent no-op.
    func testAsleepPaneMustNotBeRecreatedOnEmbed() {
        XCTAssertFalse(
            Station.shouldCreateSurfaceOnEmbed(hasSurface: false, isAsleep: true),
            "embed must leave asleep panes alone so Wake can recreate them"
        )
        XCTAssertTrue(
            Station.shouldCreateSurfaceOnEmbed(hasSurface: false, isAsleep: false),
            "a never-created pane still needs create on first embed"
        )
        XCTAssertFalse(
            Station.shouldCreateSurfaceOnEmbed(hasSurface: true, isAsleep: false)
        )
    }

    /// If embed already put a surface back while isAsleep stayed true, Wake
    /// must adopt it rather than bail.
    func testWakeAdoptsSurfaceCreatedWhileAsleep() {
        XCTAssertEqual(
            Station.wakePlan(isAsleep: true, hasSurface: true, hasContainer: false),
            .adoptExisting
        )
    }

    func testWakeRecreatesWhenSurfaceGoneAndContainerAvailable() {
        XCTAssertEqual(
            Station.wakePlan(isAsleep: true, hasSurface: false, hasContainer: true),
            .recreate
        )
        XCTAssertEqual(
            Station.wakePlan(isAsleep: true, hasSurface: false, hasContainer: false),
            .noop,
            "no container and no surface → nothing Wake can do"
        )
        XCTAssertEqual(
            Station.wakePlan(isAsleep: false, hasSurface: false, hasContainer: true),
            .noop
        )
    }
}
