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
