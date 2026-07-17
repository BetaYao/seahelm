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

    func testDidFindReleaseAutomaticallyStartsDownload() {
        let fakeUpdateManager = FakeUpdateManager()
        let coordinator = UpdateCoordinator(
            config: Config(),
            updateChecker: UpdateChecker(currentVersion: "2.0.0"),
            updateManager: fakeUpdateManager
        )
        let release = makeRelease(version: "2.1.0")

        coordinator.updateChecker(UpdateChecker(currentVersion: "2.0.0"), didFindRelease: release)

        XCTAssertEqual(coordinator.pendingRelease?.version, "2.1.0")
        XCTAssertEqual(coordinator.banner.version, "2.1.0")
        XCTAssertEqual(fakeUpdateManager.downloadedVersions, ["2.1.0"])
    }

    func testDidFindSameReleaseDoesNotStartDuplicateDownload() {
        let fakeUpdateManager = FakeUpdateManager()
        let coordinator = UpdateCoordinator(
            config: Config(),
            updateChecker: UpdateChecker(currentVersion: "2.0.0"),
            updateManager: fakeUpdateManager
        )
        let release = makeRelease(version: "2.1.0")

        coordinator.updateChecker(UpdateChecker(currentVersion: "2.0.0"), didFindRelease: release)
        coordinator.updateChecker(UpdateChecker(currentVersion: "2.0.0"), didFindRelease: release)

        XCTAssertEqual(fakeUpdateManager.downloadedVersions, ["2.1.0"])
    }

    func testRetryDownloadsPendingReleaseAgain() {
        let fakeUpdateManager = FakeUpdateManager()
        let coordinator = UpdateCoordinator(
            config: Config(),
            updateChecker: UpdateChecker(currentVersion: "2.0.0"),
            updateManager: fakeUpdateManager
        )
        let release = makeRelease(version: "2.1.0")
        coordinator.updateChecker(UpdateChecker(currentVersion: "2.0.0"), didFindRelease: release)
        coordinator.updateManager(fakeUpdateManager, didChangeState: .failed(.extractionFailed))

        coordinator.updateBannerDidClickRetry(UpdateBanner())

        XCTAssertEqual(fakeUpdateManager.downloadedVersions, ["2.1.0", "2.1.0"])
    }

    func testSkipClearsPendingReleaseAndDismissesBanner() {
        let fakeUpdateManager = FakeUpdateManager()
        let coordinator = UpdateCoordinator(
            config: Config(),
            updateChecker: UpdateChecker(currentVersion: "2.0.0"),
            updateManager: fakeUpdateManager
        )
        coordinator.updateChecker(UpdateChecker(currentVersion: "2.0.0"), didFindRelease: makeRelease(version: "2.1.0"))

        coordinator.handleSkip(version: "2.1.0")

        XCTAssertEqual(coordinator.config.autoUpdate.skippedVersion, "2.1.0")
        XCTAssertNil(coordinator.pendingRelease)
    }

    private func makeRelease(version: String) -> ReleaseInfo {
        ReleaseInfo(
            version: version,
            downloadURL: URL(string: "https://example.com/seahelm.zip")!,
            releaseNotes: "",
            publishedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

private final class FakeUpdateManager: UpdateManaging {
    weak var delegate: UpdateManagerDelegate?
    private(set) var downloadedVersions: [String] = []
    private(set) var installAndRestartCallCount = 0

    func download(release: ReleaseInfo) {
        downloadedVersions.append(release.version)
    }

    func installAndRestart() {
        installAndRestartCallCount += 1
    }
}
