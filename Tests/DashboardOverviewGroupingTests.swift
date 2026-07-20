import XCTest
@testable import seahelm

final class DashboardOverviewGroupingTests: XCTestCase {
    func testGroupingItemCarriesIdentityRepositoryStatusAndActivityDate() {
        let lastActivityAt = Date(timeIntervalSince1970: 1_721_234_567)
        let creationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sailor = makeSailor(
            id: "station-42",
            project: "seahelm",
            worktreePath: "/tmp/seahelm-feature",
            paneStatuses: [.running, .error],
            isMainWorktree: true,
            lastActivityAt: lastActivityAt
        )

        let item = sailor.groupingItem(creationDate: creationDate)

        XCTAssertEqual(item.id, "station-42")
        XCTAssertEqual(item.path, "/tmp/seahelm-feature")
        XCTAssertEqual(item.repository, "seahelm")
        XCTAssertEqual(item.status, .error)
        XCTAssertEqual(item.lastActivityAt, lastActivityAt)
        XCTAssertTrue(item.isMainWorktree)
        XCTAssertEqual(item.creationDate, creationDate)
    }
}

private func makeSailor(
    id: String,
    project: String,
    worktreePath: String,
    paneStatuses: [SailorStatus],
    isMainWorktree: Bool,
    lastActivityAt: Date?
) -> SailorDisplayInfo {
    let surface = Station()
    return SailorDisplayInfo(
        id: id,
        name: id,
        project: project,
        thread: "feature",
        paneStatuses: paneStatuses,
        mostRecentMessage: "Working",
        lastUserPrompt: "Implement grouping",
        mostRecentPaneIndex: 0,
        totalDuration: "00:01:00",
        roundDuration: "00:00:30",
        station: surface,
        worktreePath: worktreePath,
        paneCount: paneStatuses.count,
        paneStations: [surface],
        isMainWorktree: isMainWorktree,
        tasks: [],
        activityEvents: [],
        lastActivityAge: "1m",
        lastActivityAt: lastActivityAt,
        gitStats: nil,
        currentPaneTitle: id,
        currentPaneRunTime: "30s"
    )
}
