import XCTest
@testable import seahelm

private class MockTerminalCoordinatorDelegate: TerminalCoordinatorDelegate {
    var surfacesUpdated = false
    var deletedWorktree: WorktreeInfo?

    func terminalCoordinatorDidUpdateSurfaces(_ coordinator: TerminalCoordinator) {
        surfacesUpdated = true
    }

    func terminalCoordinator(_ coordinator: TerminalCoordinator, didDeleteWorktree info: WorktreeInfo) {
        deletedWorktree = info
    }
}

final class TerminalCoordinatorTests: XCTestCase {

    func testSurfaceManagerAccess() {
        let coordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        XCTAssertNotNil(coordinator.surfaceManager)
    }

    func testSaveSplitLayoutPersistsToConfig() {
        let coordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        let tree = SplitTree(worktreePath: "/tmp/test", rootLeafId: "leaf-1", surfaceId: "surface-1", sessionName: "test")
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
        XCTAssertNil(coordinator.webhookServer)
    }
}
