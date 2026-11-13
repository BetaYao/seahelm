import AppKit
import XCTest
@testable import seahelm

final class DashboardOverviewGroupingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testGroupingItemCarriesIdentityRepositoryStatusAndActivityDate() {
        let lastActivityAt = Date(timeIntervalSince1970: 1_721_234_567)
        let creationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let pane = makePane(
            name: "station-42",
            project: "seahelm",
            worktreePath: "/tmp/seahelm-feature",
            paneStatuses: [.running, .error],
            isMainWorktree: true,
            lastActivityAt: lastActivityAt
        )

        let item = pane.groupingItem(creationDate: creationDate)

        XCTAssertEqual(item.id, "/tmp/seahelm-feature", "row identity is the worktree path")
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
            view.selectedId = "/run"
            view.update([
                makePane(name: "idle", project: "charlie", worktreePath: "/idle",
                           paneStatuses: [.idle], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-300)),
                makePane(name: "wait", project: "alpha", worktreePath: "/wait",
                           paneStatuses: [.waiting], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-100)),
                makePane(name: "run", project: "bravo", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-200)),
            ])
            var callbackCount = 0
            view.onGroupingChanged = { callbackCount += 1 }

            view.selectGroupingModeForTesting(.status)

            XCTAssertEqual(defaults.string(forKey: WorktreeGroupingPreference.key), "status")
            XCTAssertEqual(view.renderedGroupTitlesForTesting, ["Needs input", "Running", "Idle"])
            XCTAssertEqual(view.orderedRows.map(\.id), ["/wait", "/run", "/idle"])
            XCTAssertEqual(view.selectedId, "/run")
            XCTAssertEqual(view.renderedSelectedRowIDForTesting, "/run")
            XCTAssertEqual(view.revealedRowIDForTesting, "/run")
            XCTAssertEqual(callbackCount, 1)
        }
    }

    func testGroupingModeSwitchFallsBackFromStaleSelectionToFirstRow() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.selectedId = "/removed"
            view.update([
                makePane(name: "idle", project: "charlie", worktreePath: "/idle",
                           paneStatuses: [.idle], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-300)),
                makePane(name: "wait", project: "alpha", worktreePath: "/wait",
                           paneStatuses: [.waiting], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-100)),
                makePane(name: "run", project: "bravo", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-200)),
            ])

            view.selectGroupingModeForTesting(.status)

            XCTAssertEqual(view.orderedRows.map(\.id), ["/wait", "/run", "/idle"])
            XCTAssertEqual(view.selectedId, "/wait")
            XCTAssertEqual(view.renderedSelectedRowIDForTesting, "/wait")
            XCTAssertEqual(view.revealedRowIDForTesting, "/wait")
        }
    }

    func testGroupingButtonDescriptionReflectsCurrentMode() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: .zero, defaults: defaults, now: { self.now })

            XCTAssertEqual(view.groupingButtonToolTipForTesting, "Group worktrees by project")
            XCTAssertEqual(view.groupingButtonAccessibilityLabelForTesting,
                           "Group worktrees by project")

            view.selectGroupingModeForTesting(.activityTime)

            XCTAssertEqual(view.groupingButtonToolTipForTesting, "Group worktrees by time")
            XCTAssertEqual(view.groupingButtonAccessibilityLabelForTesting,
                           "Group worktrees by time")
        }
    }

    func testProjectGroupsCarryAnAddWorktreeButtonAndStatusGroupsDoNot() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.update([
                makePane(name: "wait", project: "alpha", worktreePath: "/wait",
                           paneStatuses: [.waiting], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-100)),
                makePane(name: "run", project: "bravo", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-200)),
            ])

            XCTAssertEqual(view.addWorktreeProjectsForTesting, ["alpha", "bravo"])

            view.selectGroupingModeForTesting(.pane)
            XCTAssertEqual(view.addWorktreeProjectsForTesting, ["alpha", "bravo"])

            view.selectGroupingModeForTesting(.status)
            XCTAssertEqual(view.addWorktreeProjectsForTesting, [])
        }
    }

    func testProjectGroupsOfferCloseProjectAndStatusGroupsDoNot() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.update([
                makePane(name: "wait", project: "alpha", worktreePath: "/wait",
                           paneStatuses: [.waiting], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-100)),
                makePane(name: "run", project: "bravo", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-200)),
            ])

            XCTAssertEqual(view.closeableProjectsForTesting, ["alpha", "bravo"])
            XCTAssertEqual(view.closeProjectButtonsForTesting, ["alpha", "bravo"])

            var closed: String?
            view.onCloseProject = { closed = $0 }
            view.simulateCloseProjectForTesting("alpha")
            XCTAssertEqual(closed, "alpha")

            view.selectGroupingModeForTesting(.status)
            XCTAssertEqual(view.closeableProjectsForTesting, [])
            XCTAssertEqual(view.closeProjectButtonsForTesting, [])
        }
    }

    // MARK: - existing integration checkouts

    private func fleetWithIntegration() -> [WorktreeRowInfo] {
        [
            makePane(name: "main", project: "alpha", worktreePath: "/alpha",
                     paneStatuses: [.idle], isMainWorktree: true,
                     lastActivityAt: now.addingTimeInterval(-100)),
            makePane(name: "integration", project: "alpha", worktreePath: "/alpha-worktrees/integration",
                     paneStatuses: [.idle], isMainWorktree: false,
                     lastActivityAt: now.addingTimeInterval(-50)),
            makePane(name: "feature", project: "alpha", worktreePath: "/alpha-worktrees/feature",
                     paneStatuses: [.idle], isMainWorktree: false,
                     lastActivityAt: now.addingTimeInterval(-10)),
        ]
    }

    private func makeViewWithIntegrationCheckout(defaults: UserDefaults) -> DashboardOverviewView {
        DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                              defaults: defaults, now: { self.now },
                              isIntegrationWorktree: { $0 == "/alpha-worktrees/integration" })
    }

    /// A checkout that already exists is still recognised: it pins directly
    /// below main, and the status grouping leaves it out. Nothing on screen
    /// offers to run an integration.
    func testExistingCheckoutStillPinsBelowMainAndLeavesStatusGroups() {
        withDefaults { defaults in
            let view = makeViewWithIntegrationCheckout(defaults: defaults)
            view.update(fleetWithIntegration())
            XCTAssertEqual(view.orderedRows.map(\.path),
                           ["/alpha", "/alpha-worktrees/integration", "/alpha-worktrees/feature"])

            view.selectGroupingModeForTesting(.status)
            XCTAssertFalse(view.orderedRows.map(\.path).contains("/alpha-worktrees/integration"))
        }
    }

    /// The row shows an ordinary status dot — no integration state glyph.
    func testExistingCheckoutRowShowsAnOrdinaryStatusDot() {
        withDefaults { defaults in
            let view = makeViewWithIntegrationCheckout(defaults: defaults)
            view.update(fleetWithIntegration())
            XCTAssertEqual(view.rowGlyphsForTesting["/alpha-worktrees/integration"], AgentStatus.idle.glyph)
        }
    }

    // MARK: - ready to clean up

    /// The mark takes the dot's place, and goes when the flag does — rows are
    /// reused across incremental updates.
    func testACleanupCandidateShowsTheMarkInPlaceOfItsDot() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults, now: { self.now },
                                             isIntegrationWorktree: { _ in false })
            var stale = makePane(name: "stale", project: "alpha", worktreePath: "/a/stale",
                                 paneStatuses: [.idle], isMainWorktree: false,
                                 lastActivityAt: now.addingTimeInterval(-3 * 86_400))
            stale.isCleanupCandidate = true
            let fresh = makePane(name: "fresh", project: "alpha", worktreePath: "/a/fresh",
                                 paneStatuses: [.idle], isMainWorktree: false,
                                 lastActivityAt: now.addingTimeInterval(-60))
            view.update([stale, fresh])

            XCTAssertEqual(view.rowGlyphsForTesting["/a/stale"], DashboardOverviewView.cleanupSymbolName)
            XCTAssertEqual(view.rowGlyphsForTesting["/a/fresh"], AgentStatus.idle.glyph)

            stale.isCleanupCandidate = false
            view.update([stale, fresh])
            XCTAssertEqual(view.rowGlyphsForTesting["/a/stale"], AgentStatus.idle.glyph)
        }
    }

    func testPausedRenderHoldsRowsUntilResumed() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.update([
                makePane(name: "wait", project: "alpha", worktreePath: "/wait",
                           paneStatuses: [.waiting], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-100)),
            ])

            // A create popover is anchored into these rows: a poll must not
            // rebuild them out from under it.
            view.isRenderPaused = true
            view.update([
                makePane(name: "wait", project: "alpha", worktreePath: "/wait",
                           paneStatuses: [.waiting], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-100)),
                makePane(name: "run", project: "bravo", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-200)),
            ])
            XCTAssertEqual(view.orderedRows.map(\.id), ["/wait"])

            view.isRenderPaused = false
            XCTAssertEqual(view.orderedRows.map(\.id), ["/wait", "/run"])
        }
    }

    func testUpdateWithSameStructureSkipsFullRebuildAndRefreshesRuntimeText() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.update([
                makePane(name: "run", project: "alpha", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-20),
                           currentPaneRunTime: "10s"),
            ])

            XCTAssertEqual(view.fullRenderCountForTesting, 1)
            XCTAssertEqual(view.rowRuntimeTextForTesting(id: "/run"), "10s")

            view.update([
                makePane(name: "run", project: "alpha", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-10),
                           currentPaneRunTime: "20s"),
            ])

            XCTAssertEqual(view.fullRenderCountForTesting, 1)
            XCTAssertEqual(view.rowRuntimeTextForTesting(id: "/run"), "20s")
        }
    }

    func testIncrementalUpdateDoesNotBlankTitleWhenIncomingTitleIsEmpty() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.update([
                makePane(name: "run", project: "alpha", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-20),
                           currentPaneTitle: "Initial title"),
            ])
            XCTAssertEqual(view.rowTitleTextForTesting(id: "/run"), "Initial title")

            view.update([
                makePane(name: "run", project: "alpha", worktreePath: "/run",
                           paneStatuses: [.running], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-10),
                           currentPaneTitle: "   "),
            ])
            XCTAssertEqual(view.rowTitleTextForTesting(id: "/run"), "Initial title")
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
            func push(_ status: AgentStatus, runtime: String) {
                view.update([
                    makePane(name: "run", project: "alpha", worktreePath: "/run",
                               paneStatuses: [status], isMainWorktree: false,
                               lastActivityAt: now.addingTimeInterval(-10),
                               currentPaneRunTime: runtime),
                ])
            }

            push(.running, runtime: "12s")
            XCTAssertEqual(view.rowRuntimeTextForTesting(id: "/run"), "12s")

            // Still running, value momentarily unavailable — hold the last figure.
            push(.running, runtime: "")
            XCTAssertEqual(view.rowRuntimeTextForTesting(id: "/run"), "12s")

            // Stopped with no known activity age — the counter must go away.
            push(.idle, runtime: "")
            XCTAssertEqual(view.rowRuntimeTextForTesting(id: "/run"), "")

            XCTAssertEqual(view.fullRenderCountForTesting, 1, "these should all be incremental")
        }
    }

    /// Regression: the status dot is a plain `addSubview` child, so it has to opt
    /// out of autoresizing constraints by hand. Without that, the frame-derived
    /// constraints win and the whole text column lays out at zero height — every
    /// row paints as a bare dot with no title, branch, or timings.
    /// Scrolling the fleet under a stationary pointer used to deliver an enter
    /// for every row that slid past and no matching exit, leaving a column of
    /// rows tinted as if they were all selected.
    func testHoverTintNeverLandsOnMoreThanOneRow() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.update([
                makePane(name: "one", project: "alpha", worktreePath: "/one",
                         paneStatuses: [.running], isMainWorktree: false,
                         lastActivityAt: now.addingTimeInterval(-10)),
                makePane(name: "two", project: "alpha", worktreePath: "/two",
                         paneStatuses: [.waiting], isMainWorktree: false,
                         lastActivityAt: now.addingTimeInterval(-20)),
                makePane(name: "three", project: "alpha", worktreePath: "/three",
                         paneStatuses: [.idle], isMainWorktree: false,
                         lastActivityAt: now.addingTimeInterval(-30)),
            ])

            view.simulateRowHoverForTesting(id: "/one", entered: true)
            XCTAssertEqual(view.hoveredRowIDsForTesting, ["/one"])

            // Rows sliding past the pointer: enters with no exits.
            view.simulateRowHoverForTesting(id: "/two", entered: true)
            view.simulateRowHoverForTesting(id: "/three", entered: true)
            XCTAssertEqual(view.hoveredRowIDsForTesting, ["/three"])

            // A stale exit for a row the pointer already left must not blank the
            // row that is actually under it.
            view.simulateRowHoverForTesting(id: "/one", entered: false)
            XCTAssertEqual(view.hoveredRowIDsForTesting, ["/three"])

            view.simulateRowHoverForTesting(id: "/three", entered: false)
            XCTAssertEqual(view.hoveredRowIDsForTesting, [])
        }
    }

    func testWorktreeRowLaysOutTitleWithRealSize() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.update([
                makePane(name: "run", project: "alpha", worktreePath: "/run",
                           paneStatuses: [.idle], isMainWorktree: false,
                           lastActivityAt: now.addingTimeInterval(-20),
                           currentPaneTitle: "claude — building"),
            ])
            view.layoutSubtreeIfNeeded()

            let frame = view.rowTitleFrameForTesting(id: "/run")
            XCTAssertNotNil(frame)
            XCTAssertGreaterThan(frame?.height ?? 0, 0, "row title collapsed to zero height")
            XCTAssertGreaterThan(frame?.width ?? 0, 0, "row title collapsed to zero width")
        }
    }

    // MARK: - Session labels

    /// The ribbon is the whole feature: a labelled row wears its colour, an
    /// unlabelled one wears none, and picking a colour repaints that row alone.
    func testRowRibbonFollowsTheWorktreeLabel() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.update([
                makePane(name: "run", project: "alpha", worktreePath: "/run",
                         paneStatuses: [.running], isMainWorktree: false,
                         lastActivityAt: now.addingTimeInterval(-100), label: .teal),
                makePane(name: "idle", project: "alpha", worktreePath: "/idle",
                         paneStatuses: [.idle], isMainWorktree: false,
                         lastActivityAt: now.addingTimeInterval(-200)),
            ])

            XCTAssertEqual(view.rowLabelsForTesting["/run"] ?? nil, .teal)
            XCTAssertNil(view.rowLabelsForTesting["/idle"] ?? nil)

            view.setLabel(.pink, forWorktree: "/idle")
            XCTAssertEqual(view.rowLabelsForTesting["/idle"] ?? nil, .pink)
            XCTAssertEqual(view.rowLabelsForTesting["/run"] ?? nil, .teal, "one row's pick must not touch another")

            view.setLabel(nil, forWorktree: "/run")
            XCTAssertNil(view.rowLabelsForTesting["/run"] ?? nil)
        }
    }

    /// A label-only change is content, not structure, so the list reuses the
    /// existing row views. The ribbon has to be refreshed on that path too, or
    /// it goes stale until something else forces a full rebuild.
    func testLabelChangeSurvivesTheIncrementalUpdatePath() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            let unlabelled = makePane(name: "run", project: "alpha", worktreePath: "/run",
                                      paneStatuses: [.running], isMainWorktree: false,
                                      lastActivityAt: now.addingTimeInterval(-100))
            view.update([unlabelled])
            let rendersAfterFirst = view.fullRenderCountForTesting
            XCTAssertNil(view.rowLabelsForTesting["/run"] ?? nil)

            view.update([
                makePane(name: "run", project: "alpha", worktreePath: "/run",
                         paneStatuses: [.running], isMainWorktree: false,
                         lastActivityAt: now.addingTimeInterval(-100), label: .green),
            ])

            XCTAssertEqual(view.fullRenderCountForTesting, rendersAfterFirst,
                           "precondition: a label change should take the incremental path")
            XCTAssertEqual(view.rowLabelsForTesting["/run"] ?? nil, .green)
        }
    }

    /// A pick lands before the coordinator re-reads the store, so the overview
    /// still holds the unlabelled rows it was last handed. Re-rendering from
    /// those — here, the create popover closing — must not strip the ribbon.
    func testPickedLabelSurvivesARerenderFromCachedRows() {
        withDefaults { defaults in
            let view = DashboardOverviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                             defaults: defaults,
                                             now: { self.now })
            view.update([
                makePane(name: "run", project: "alpha", worktreePath: "/run",
                         paneStatuses: [.running], isMainWorktree: false,
                         lastActivityAt: now.addingTimeInterval(-100)),
            ])

            view.setLabel(.purple, forWorktree: "/run")
            view.isRenderPaused = true
            view.isRenderPaused = false

            XCTAssertEqual(view.rowLabelsForTesting["/run"] ?? nil, .purple)
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

/// The words a remote list draws a row with come from here, so the web and
/// the dashboard cannot disagree about what a worktree is called.
final class WorktreeRowWordsTests: XCTestCase {
    func testTitleIsTheFocusedPanesTitleTrimmed() {
        let row = makePane(name: "fix-y", project: "alpha", worktreePath: "/w/fix-y", paneStatuses: [.idle],
                           isMainWorktree: false, lastActivityAt: nil, currentPaneTitle: "  Telegram 话题设计 \n")
        XCTAssertEqual(row.rowTitle, "Telegram 话题设计")
        XCTAssertEqual(row.rowSubtitle, "feature")
    }

    func testNoTitleIsNilSoTheCallerChoosesTheFallback() {
        let row = makePane(name: "fix-y", project: "alpha", worktreePath: "/w/fix-y", paneStatuses: [.idle],
                           isMainWorktree: false, lastActivityAt: nil, currentPaneTitle: "   ")
        XCTAssertNil(row.rowTitle)
    }
}

private func makePane(
    name: String,
    project: String,
    worktreePath: String,
    paneStatuses: [AgentStatus],
    isMainWorktree: Bool,
    lastActivityAt: Date?,
    currentPaneTitle: String? = nil,
    currentPaneRunTime: String = "30s",
    label: SessionLabel? = nil
) -> WorktreeRowInfo {
    let surface = Station()
    return WorktreeRowInfo(
        name: name,
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
        currentPaneTitle: currentPaneTitle ?? name,
        currentPaneRunTime: currentPaneRunTime,
        label: label
    )
}
