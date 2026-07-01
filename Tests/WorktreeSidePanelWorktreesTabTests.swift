import XCTest
@testable import seahelm

final class WorktreeSidePanelWorktreesTabTests: XCTestCase {
    func testWorktreesTabEmbedsProvidedView() {
        let vc = WorktreeSidePanelViewController(worktreePath: nil, initialTab: .files)
        _ = vc.view  // force loadView
        let stub = NSView()
        vc.worktreesTabView = stub
        vc.selectTab(.worktrees)
        XCTAssertEqual(vc.selectedTabForTesting, .worktrees)
        XCTAssertNotNil(stub.superview, "the provided worktrees view should be embedded")
    }

    func testWorktreesTabWithNoViewShowsPlaceholderNotCrash() {
        let vc = WorktreeSidePanelViewController(worktreePath: nil, initialTab: .files)
        _ = vc.view
        vc.worktreesTabView = nil
        vc.selectTab(.worktrees)   // must not crash
        XCTAssertEqual(vc.selectedTabForTesting, .worktrees)
    }
}
