import AppKit
import XCTest
@testable import seahelm

final class DashboardOverviewGroupingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

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

    func testGroupingMenuUsesApprovedTitlesAndHasNoKeyboardShortcuts() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })

            XCTAssertEqual(view.groupingMenuTitlesForTesting, [
                "Group by Repository", "Group by Status", "Group by Time", "Expand All Panes",
            ])
            XCTAssertEqual(view.groupingMenuKeyEquivalentsForTesting, ["", "", "", ""])
            XCTAssertTrue(view.groupingButtonRefusesFirstResponderForTesting)
        }
    }

    func testStoredStatusLoadsAsTheOnlyCheckedMode() {
        withDefaults { defaults in
            defaults.set("status", forKey: WorktreeGroupingPreference.key)

            let view = DashboardOverviewView(frame: .zero, defaults: defaults, now: { self.now })

            XCTAssertEqual(view.groupingModeForTesting, .status)
            XCTAssertEqual(view.checkedGroupingModesForTesting, [.status])
        }
    }

    func testInvalidStoredModeFallsBackToRepository() {
        withDefaults { defaults in
            defaults.set("not-a-mode", forKey: WorktreeGroupingPreference.key)

            let view = DashboardOverviewView(frame: .zero, defaults: defaults, now: { self.now })

            XCTAssertEqual(view.groupingModeForTesting, .repository)
            XCTAssertEqual(view.checkedGroupingModesForTesting, [.repository])
        }
    }

    func testChoosingStatusPersistsRendersAndRevealsSelectedRow() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.selectedId = "run"
            view.update([
                makeSailor(id: "idle", project: "charlie", worktreePath: "/idle",
                           paneStatuses: [.idle], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-300)),
                makeSailor(id: "wait", project: "alpha", worktreePath: "/wait",
                           paneStatuses: [.waiting], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-100)),
                makeSailor(id: "run", project: "bravo", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-200)),
            ])
            var callbackCount = 0
            view.onGroupingChanged = { callbackCount += 1 }

            view.selectGroupingModeForTesting(.status)

            XCTAssertEqual(defaults.string(forKey: WorktreeGroupingPreference.key), "status")
            XCTAssertEqual(view.renderedGroupTitlesForTesting, ["Needs input", "Running", "Idle"])
            XCTAssertEqual(view.orderedRows.map(\.id), ["wait", "run", "idle"])
            XCTAssertEqual(view.selectedId, "run")
            XCTAssertEqual(view.renderedSelectedRowIDForTesting, "run")
            XCTAssertEqual(view.revealedRowIDForTesting, "run")
            XCTAssertEqual(callbackCount, 1)
        }
    }

    func testGroupingModeSwitchFallsBackFromStaleSelectionToFirstRow() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.selectedId = "removed"
            view.update([
                makeSailor(id: "idle", project: "charlie", worktreePath: "/idle",
                           paneStatuses: [.idle], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-300)),
                makeSailor(id: "wait", project: "alpha", worktreePath: "/wait",
                           paneStatuses: [.waiting], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-100)),
                makeSailor(id: "run", project: "bravo", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-200)),
            ])

            view.selectGroupingModeForTesting(.status)

            XCTAssertEqual(view.orderedRows.map(\.id), ["wait", "run", "idle"])
            XCTAssertEqual(view.selectedId, "wait")
            XCTAssertEqual(view.renderedSelectedRowIDForTesting, "wait")
            XCTAssertEqual(view.revealedRowIDForTesting, "wait")
        }
    }

    func testGroupingButtonDescriptionReflectsCurrentMode() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: .zero, defaults: defaults, now: { self.now })

            XCTAssertEqual(view.groupingButtonToolTipForTesting, "Group worktrees by repository")
            XCTAssertEqual(view.groupingButtonAccessibilityLabelForTesting,
                           "Group worktrees by repository")

            view.selectGroupingModeForTesting(.activityTime)

            XCTAssertEqual(view.groupingButtonToolTipForTesting, "Group worktrees by time")
            XCTAssertEqual(view.groupingButtonAccessibilityLabelForTesting,
                           "Group worktrees by time")
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "DashboardOverviewGroupingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
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
