import XCTest
@testable import seahelm

/// What discovery reports as gone — and, more to the point, what it refuses to.
final class WorktreeVanishTests: XCTestCase {

    func testAWorktreeDroppedFromTheListHasVanished() {
        let gone = TabCoordinator.vanishedWorktrees(
            previous: ["/w/a", "/w/b", "/w/c"], current: ["/w/a", "/w/c"])
        XCTAssertEqual(gone, ["/w/b"])
    }

    func testNothingVanishesWhenTheListOnlyGrows() {
        XCTAssertTrue(TabCoordinator.vanishedWorktrees(
            previous: ["/w/a"], current: ["/w/a", "/w/b"]).isEmpty)
    }

    /// The guard that matters. An empty list is a failed `git worktree list` or
    /// an unmounted volume, and what hangs off this signal deletes Telegram
    /// threads — so "everything is gone" is the one reading never believed.
    func testAnEmptyListIsNotEverythingVanishing() {
        XCTAssertTrue(TabCoordinator.vanishedWorktrees(
            previous: ["/w/a", "/w/b", "/w/c"], current: []).isEmpty)
    }

    /// First run: nothing was listed before, so nothing can have gone.
    func testTheFirstDiscoveryReportsNothing() {
        XCTAssertTrue(TabCoordinator.vanishedWorktrees(
            previous: [], current: ["/w/a"]).isEmpty)
    }
}
