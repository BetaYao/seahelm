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
                "Group by Project", "Group by Status", "Group by Time", "Expand All Panes",
            ])
            XCTAssertEqual(view.groupingMenuKeyEquivalentsForTesting, ["", "", "", ""])
            XCTAssertTrue(view.groupingButtonRefusesFirstResponderForTesting)
        }
    }

    func testStoredStatusLoadsAsTheOnlyCheckedMode() {
        withDefaults { defaults in
            defaults.set("status", forKey: CabinGroupingPreference.key)

            let view = DashboardOverviewView(frame: .zero, defaults: defaults, now: { self.now })

            XCTAssertEqual(view.groupingModeForTesting, .status)
            XCTAssertEqual(view.checkedGroupingModesForTesting, [.status])
        }
    }

    func testInvalidStoredModeFallsBackToRepository() {
        withDefaults { defaults in
            defaults.set("not-a-mode", forKey: CabinGroupingPreference.key)

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

            XCTAssertEqual(defaults.string(forKey: CabinGroupingPreference.key), "status")
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

            XCTAssertEqual(view.groupingButtonToolTipForTesting, "Group cabins by deck")
            XCTAssertEqual(view.groupingButtonAccessibilityLabelForTesting,
                           "Group cabins by deck")

            view.selectGroupingModeForTesting(.activityTime)

            XCTAssertEqual(view.groupingButtonToolTipForTesting, "Group cabins by time")
            XCTAssertEqual(view.groupingButtonAccessibilityLabelForTesting,
                           "Group cabins by time")
        }
    }

    func testProjectGroupsCarryAnAddWorktreeButtonAndStatusGroupsDoNot() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.update([
                makeSailor(id: "wait", project: "alpha", worktreePath: "/wait",
                           paneStatuses: [.waiting], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-100)),
                makeSailor(id: "run", project: "bravo", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-200)),
            ])

            XCTAssertEqual(view.addWorktreeProjectsForTesting, ["alpha", "bravo"])

            view.selectGroupingModeForTesting(.sailor)
            XCTAssertEqual(view.addWorktreeProjectsForTesting, ["alpha", "bravo"])

            view.selectGroupingModeForTesting(.status)
            XCTAssertEqual(view.addWorktreeProjectsForTesting, [])
        }
    }

    func testPausedRenderHoldsRowsUntilResumed() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.update([
                makeSailor(id: "wait", project: "alpha", worktreePath: "/wait",
                           paneStatuses: [.waiting], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-100)),
            ])

            // A create popover is anchored into these rows: a poll must not
            // rebuild them out from under it.
            view.isRenderPaused = true
            view.update([
                makeSailor(id: "wait", project: "alpha", worktreePath: "/wait",
                           paneStatuses: [.waiting], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-100)),
                makeSailor(id: "run", project: "bravo", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-200)),
            ])
            XCTAssertEqual(view.orderedRows.map(\.id), ["wait"])

            view.isRenderPaused = false
            XCTAssertEqual(view.orderedRows.map(\.id), ["wait", "run"])
        }
    }

    func testUpdateWithSameStructureSkipsFullRebuildAndRefreshesRuntimeText() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.update([
                makeSailor(id: "run", project: "alpha", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-20),
                           currentPaneRunTime: "10s"),
            ])

            XCTAssertEqual(view.fullRenderCountForTesting, 1)
            XCTAssertEqual(view.rowRuntimeTextForTesting(id: "run"), "10s")

            view.update([
                makeSailor(id: "run", project: "alpha", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-10),
                           currentPaneRunTime: "20s"),
            ])

            XCTAssertEqual(view.fullRenderCountForTesting, 1)
            XCTAssertEqual(view.rowRuntimeTextForTesting(id: "run"), "20s")
        }
    }

    func testIncrementalUpdateDoesNotBlankTitleWhenIncomingTitleIsEmpty() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.update([
                makeSailor(id: "run", project: "alpha", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-20),
                           currentPaneTitle: "Initial title"),
            ])
            XCTAssertEqual(view.rowTitleTextForTesting(id: "run"), "Initial title")

            view.update([
                makeSailor(id: "run", project: "alpha", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-10),
                           currentPaneTitle: "   "),
            ])
            XCTAssertEqual(view.rowTitleTextForTesting(id: "run"), "Initial title")
        }
    }

    /// A duration must clear once the pane stops — the row would otherwise hold
    /// the last figure forever and read as "12s" next to an idle dot. A row that
    /// is still running keeps its last value so a live counter never blanks.
    func testStoppedRowClearsRuntimeButRunningRowKeepsIt() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            func push(_ status: SailorStatus, runtime: String) {
                view.update([
                    makeSailor(id: "run", project: "alpha", worktreePath: "/run",
                               paneStatuses: [status], isMainWorktree: false,
                               lastActivityAt: now.addingTimeInterval(-10),
                               currentPaneRunTime: runtime),
                ])
            }

            push(.running, runtime: "12s")
            XCTAssertEqual(view.rowRuntimeTextForTesting(id: "run"), "12s")

            // Still running, value momentarily unavailable — hold the last figure.
            push(.running, runtime: "")
            XCTAssertEqual(view.rowRuntimeTextForTesting(id: "run"), "12s")

            // Stopped with no known activity age — the counter must go away.
            push(.idle, runtime: "")
            XCTAssertEqual(view.rowRuntimeTextForTesting(id: "run"), "")

            XCTAssertEqual(view.fullRenderCountForTesting, 1, "these should all be incremental")
        }
    }

    /// Regression: the status dot is a plain `addSubview` child, so it has to opt
    /// out of autoresizing constraints by hand. Without that, the frame-derived
    /// constraints win and the whole text column lays out at zero height — every
    /// row paints as a bare dot with no title, branch, or timings.
    func testWorktreeRowLaysOutTitleWithRealSize() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.update([
                makeSailor(id: "run", project: "alpha", worktreePath: "/run",
                           paneStatuses: [.idle], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-20),
                           currentPaneTitle: "claude — building"),
            ])
            view.layoutSubtreeIfNeeded()

            let frame = view.rowTitleFrameForTesting(id: "run")
            XCTAssertNotNil(frame)
            XCTAssertGreaterThan(frame?.height ?? 0, 0, "row title collapsed to zero height")
            XCTAssertGreaterThan(frame?.width ?? 0, 0, "row title collapsed to zero width")
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
    lastActivityAt: Date?,
    currentPaneTitle: String? = nil,
    currentPaneRunTime: String = "30s"
) -> SailorDisplayInfo {
    let surface = Station()
    return SailorDisplayInfo(
        id: id,
        name: id,
        project: project,
        thread: "feature",
        paneStatuses: paneStatuses,
        rolledUpStatus: paneStatuses.first ?? .unknown,
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
        currentPaneTitle: currentPaneTitle ?? id,
        currentPaneRunTime: currentPaneRunTime
    )
}
