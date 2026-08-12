import XCTest
@testable import seahelm

final class TerminalCoordinatorTests: XCTestCase {

    func testStationManagerAccess() {
        let coordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        XCTAssertNotNil(coordinator.stationManager)
    }

    func testSaveSplitLayoutPersistsToConfig() {
        let coordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        let tree = SplitTree(worktreePath: "/tmp/test", rootLeafId: "leaf-1", stationId: "surface-1", paneSessionKey: "test")
        coordinator.saveSplitLayout(tree)
        XCTAssertNotNil(coordinator.config.splitLayouts["/tmp/test"])
    }

    func testSplitFocusedPaneWithNilRepoVCIsNoop() {
        let coordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        // Should not crash when no repoVC
        coordinator.splitFocusedPane(axis: .horizontal)
    }

    func testCloseFocusedPaneWithNilRepoVCIsNoop() {
        let coordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        coordinator.closeFocusedPane()
    }

    func testMoveFocusWithNilRepoVCIsNoop() {
        let coordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        coordinator.moveFocus(.horizontal, positive: true)
    }

    func testCleanup() {
        let coordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        coordinator.cleanup()
        XCTAssertNil(coordinator.controlSocketServer)
    }

    // MARK: - Auto sleep policy

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testOffscreenPaneIsNotSleptBeforeTheThreshold() {
        let first = TerminalCoordinator.autoSleepPlan(
            visible: [], sleepable: ["a"], offscreenSince: [:], idleAfter: 600, now: t0)
        XCTAssertEqual(first.sleep, [], "the first sighting only starts the clock")
        XCTAssertEqual(first.offscreenSince["a"], t0)

        let later = TerminalCoordinator.autoSleepPlan(
            visible: [], sleepable: ["a"], offscreenSince: first.offscreenSince,
            idleAfter: 600, now: t0.addingTimeInterval(599))
        XCTAssertEqual(later.sleep, [])
    }

    func testOffscreenPaneSleepsOnceThresholdPasses() {
        let plan = TerminalCoordinator.autoSleepPlan(
            visible: [], sleepable: ["a"], offscreenSince: ["a": t0],
            idleAfter: 600, now: t0.addingTimeInterval(600))
        XCTAssertEqual(plan.sleep, ["a"])
        XCTAssertNil(plan.offscreenSince["a"], "a slept pane's clock is meaningless")
    }

    /// `Station.sleep()` frees a Metal surface on the main thread; doing a batch
    /// in one pass measured 13-20s of main-thread stall, which reads as a hang.
    func testOnlyOnePaneSleepsPerTick() {
        let plan = TerminalCoordinator.autoSleepPlan(
            visible: [], sleepable: ["a", "b", "c", "d"],
            offscreenSince: ["a": t0, "b": t0, "c": t0, "d": t0],
            idleAfter: 600, now: t0.addingTimeInterval(6000))
        XCTAssertEqual(plan.sleep.count, 1, "a backlog must drain one pane per tick")
    }

    /// Oldest first, so a backlog drains in a defined order rather than whatever
    /// the dictionary happens to yield.
    func testOldestOffscreenPaneSleepsFirst() {
        let plan = TerminalCoordinator.autoSleepPlan(
            visible: [], sleepable: ["new", "old", "mid"],
            offscreenSince: ["new": t0.addingTimeInterval(200),
                             "old": t0,
                             "mid": t0.addingTimeInterval(100)],
            idleAfter: 600, now: t0.addingTimeInterval(6000))
        XCTAssertEqual(plan.sleep, ["old"])
    }

    /// The panes not chosen keep their clocks, or a backlog would restart its
    /// timer every tick and never drain.
    func testUnchosenPanesKeepTheirClocks() {
        let plan = TerminalCoordinator.autoSleepPlan(
            visible: [], sleepable: ["a", "b"], offscreenSince: ["a": t0, "b": t0],
            idleAfter: 600, now: t0.addingTimeInterval(6000))
        let remaining = plan.sleep == ["a"] ? "b" : "a"
        XCTAssertEqual(plan.offscreenSince[remaining], t0, "the queue must not reset")

        let next = TerminalCoordinator.autoSleepPlan(
            visible: [], sleepable: [remaining], offscreenSince: plan.offscreenSince,
            idleAfter: 600, now: t0.addingTimeInterval(6060))
        XCTAssertEqual(next.sleep, [remaining], "and it drains on the following tick")
    }

    /// The reason the clock is stored rather than accumulated: a pane the user
    /// keeps returning to must never reach the threshold by adding up gaps.
    func testReturningToScreenResetsTheClock() {
        let seen = TerminalCoordinator.autoSleepPlan(
            visible: [], sleepable: ["a"], offscreenSince: [:], idleAfter: 600, now: t0)
        let back = TerminalCoordinator.autoSleepPlan(
            visible: ["a"], sleepable: ["a"], offscreenSince: seen.offscreenSince,
            idleAfter: 600, now: t0.addingTimeInterval(300))
        XCTAssertNil(back.offscreenSince["a"], "being visible clears the clock")

        let away = TerminalCoordinator.autoSleepPlan(
            visible: [], sleepable: ["a"], offscreenSince: back.offscreenSince,
            idleAfter: 600, now: t0.addingTimeInterval(700))
        XCTAssertEqual(away.sleep, [], "the clock restarts from the moment it left again")
    }

    func testVisiblePaneIsNeverSlept() {
        let plan = TerminalCoordinator.autoSleepPlan(
            visible: ["a"], sleepable: ["a"], offscreenSince: ["a": t0],
            idleAfter: 600, now: t0.addingTimeInterval(6000))
        XCTAssertEqual(plan.sleep, [], "a pane on screen must not be slept, however stale its clock")
    }

    func testClosedPanesDropOutOfTheClock() {
        let plan = TerminalCoordinator.autoSleepPlan(
            visible: ["a"], sleepable: ["a"], offscreenSince: ["a": t0, "gone": t0],
            idleAfter: 600, now: t0.addingTimeInterval(10))
        XCTAssertNil(plan.offscreenSince["gone"], "ids that no longer exist must not accumulate")
    }
}
