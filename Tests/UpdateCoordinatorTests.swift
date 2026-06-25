import XCTest
@testable import seahelm

final class UpdateCoordinatorTests: XCTestCase {

    func testInitCreatesComponents() {
        let coordinator = UpdateCoordinator(config: Config())
        XCTAssertNotNil(coordinator.banner)
        XCTAssertNotNil(coordinator.updateChecker)
        XCTAssertNotNil(coordinator.updateManager)
        XCTAssertNil(coordinator.pendingRelease)
    }

    func testSetupAutoUpdateWhenDisabled() {
        var config = Config()
        config.autoUpdate.enabled = false
        let coordinator = UpdateCoordinator(config: config)
        // Should not crash when autoUpdate is disabled
        coordinator.setup(config: config)
    }

    func testHandleSkipSavesVersion() {
        var config = Config()
        config.autoUpdate.enabled = false
        let coordinator = UpdateCoordinator(config: config)
        coordinator.handleSkip(version: "2.0.0")
        XCTAssertEqual(coordinator.config.autoUpdate.skippedVersion, "2.0.0")
        XCTAssertNil(coordinator.pendingRelease)
    }
}
