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
}
