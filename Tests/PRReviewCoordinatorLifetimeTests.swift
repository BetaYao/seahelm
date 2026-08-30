import XCTest
@testable import seahelm

/// Who keeps the coordinator alive.
///
/// Callers reach this as `PRReviewCoordinator(...).show()` and keep no
/// reference. With `[weak self]` in the row callback, the coordinator died the
/// moment `show()` returned, so clicking a PR resolved `self` to nil and the
/// panel could never leave the list for a diff.
final class PRReviewCoordinatorLifetimeTests: XCTestCase {

    func testCoordinatorOutlivesShowSoARowClickStillHasSomewhereToGo() {
        let dashboard = DashboardViewController()
        dashboard.loadViewIfNeeded()

        weak var weakCoordinator: PRReviewCoordinator?
        autoreleasepool {
            let coordinator = PRReviewCoordinator(
                service: GitHubPRService(token: "t", owner: "o", repo: "r"),
                dashboard: dashboard
            )
            weakCoordinator = coordinator
            coordinator.show()
            // Exactly what the caller does: drops its only reference.
        }

        XCTAssertNotNil(weakCoordinator,
                        "the presented list has to keep the coordinator alive, or every row click is a no-op")
    }

    /// And it is not immortal: closing the panel has to let it go, or every
    /// visit to the PR panel leaks one plus its in-flight requests.
    func testCoordinatorIsReleasedWhenTheOverlayGoes() {
        let dashboard = DashboardViewController()
        dashboard.loadViewIfNeeded()

        weak var weakCoordinator: PRReviewCoordinator?
        autoreleasepool {
            let coordinator = PRReviewCoordinator(
                service: GitHubPRService(token: "t", owner: "o", repo: "r"),
                dashboard: dashboard
            )
            weakCoordinator = coordinator
            coordinator.show()
        }
        XCTAssertNotNil(weakCoordinator)

        autoreleasepool { dashboard.dismissCenterOverlay() }
        // `dismissCenterOverlay` hands the overlay's release to the next runloop
        // turn on purpose, so the click feels instant. Give it that turn.
        let deadline = Date().addingTimeInterval(2)
        while weakCoordinator != nil, Date() < deadline {
            autoreleasepool { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        }
        XCTAssertNil(weakCoordinator, "closing the panel must drop the coordinator")
    }
}
