import XCTest
@testable import seahelm

/// What First Mate marks, and what it leaves alone.
final class IntegrationAttentionTests: XCTestCase {
    private func state(included: [String] = [], excluded: [IntegrationPanelState.Excluded] = [],
                       conflicted: [String] = [], held: Bool = false,
                       failure: String? = nil) -> IntegrationPanelState {
        IntegrationPanelState(line: "l", included: included, excluded: excluded,
                              conflictedPaths: conflicted, isHeld: held, failure: failure)
    }

    /// A clean publish is meant to be invisible — the checkout is simply current.
    func testACleanRoundIsNotMarked() {
        XCTAssertFalse(state(included: ["a", "b"]).needsAttention)
    }

    func testEveryWayARoundFailsToLandIsMarked() {
        XCTAssertTrue(state(excluded: [.init(label: "b", paths: ["f.swift"])]).needsAttention,
                      "work was dropped")
        XCTAssertTrue(state(conflicted: ["f.swift"]).needsAttention,
                      "what landed carries conflict markers")
        XCTAssertTrue(state(held: true).needsAttention,
                      "built but not checked out")
        XCTAssertTrue(state(failure: "no base ref").needsAttention,
                      "the round never ran")
    }

    /// State written before `failure` existed still decodes, and reads as the
    /// clean round it was.
    func testOlderStateStillDecodes() throws {
        let raw = """
        {"line":"integration · 2 worktrees","included":["a","b"],"excluded":[],
         "conflictedPaths":[],"isHeld":false}
        """
        let decoded = try XCTUnwrap(IntegrationStatusStore.decode(raw))
        XCTAssertNil(decoded.failure)
        XCTAssertFalse(decoded.needsAttention)
    }

    /// A round that threw used to write nothing, leaving the last good round on
    /// screen — First Mate claiming an integration that no longer existed.
    func testAFailedRoundReplacesTheLastGoodLine() {
        let failed = IntegrationPanelState.failed("no base ref")
        XCTAssertEqual(failed.line, "integration · failed · no base ref")
        XCTAssertTrue(failed.needsAttention)
        XCTAssertTrue(failed.included.isEmpty)
    }

    /// The report's own line says it too, so the text and the marker agree.
    func testReportCarriesTheFailureIntoItsPanelState() {
        let report = IntegrationRunReport(
            integrationWorktreePath: "/wt/integration",
            result: IntegrationResult(commit: "c", tree: "t", base: "b",
                                      included: [], excluded: [], conflictedPaths: []),
            outcome: .failed("merge refused"),
            unsnapshotable: [],
            committedOnly: []
        )
        XCTAssertTrue(report.needsAttention)
        XCTAssertEqual(report.panelState.failure, "merge refused")
        XCTAssertTrue(report.panelState.needsAttention)
        XCTAssertTrue(report.cardLine.contains("failed · merge refused"), report.cardLine)
    }

    // MARK: - how a checkout reads in the list

    func testTheRowDotSaysWhatTheLastRoundDid() {
        XCTAssertEqual(IntegrationRowStatus(nil), .notBuilt)
        XCTAssertEqual(IntegrationRowStatus(state(included: ["a"])), .clean)
        XCTAssertEqual(IntegrationRowStatus(state(held: true)), .attention)
        XCTAssertEqual(IntegrationRowStatus(state(excluded: [.init(label: "b", paths: [])])), .attention)
        XCTAssertEqual(IntegrationRowStatus(state(failure: "no base ref")), .failed)
    }

    /// Four states, four glyphs, all one column wide so the list stays aligned.
    func testEveryRowStateHasItsOwnSingleColumnGlyph() {
        let glyphs = [IntegrationRowStatus.notBuilt, .clean, .attention, .failed].map(\.glyph)
        XCTAssertEqual(Set(glyphs).count, glyphs.count)
        XCTAssertTrue(glyphs.allSatisfy { $0.count == 1 }, "\(glyphs)")
    }

    // MARK: - which checkouts the banner shows

    /// Grouping by status or activity leaves the checkout out of the list, so
    /// the banner is the only place it can be seen there.
    func testOnlyTheGroupingsWithoutARowGetABanner() {
        for mode in [WorktreeGroupingMode.status, .activityTime] {
            XCTAssertEqual(DashboardOverviewView.bannerPaths(checkouts: ["/a", "/b"], mode: mode),
                           ["/a", "/b"])
        }
        for mode in [WorktreeGroupingMode.repository, .pane] {
            XCTAssertEqual(DashboardOverviewView.bannerPaths(checkouts: ["/a", "/b"], mode: mode), [],
                           "the row already carries it")
        }
    }

    func testTheMarkedLineIsOneColumnApartFromTheCleanOne() {
        let clean = DashboardOverviewView.bannerLine(project: "alpha", status: "integration · 2 worktrees",
                                                     needsAttention: false)
        let marked = DashboardOverviewView.bannerLine(project: "alpha", status: "integration · 2 worktrees",
                                                      needsAttention: true)
        XCTAssertEqual(clean.text, "\u{2443}  alpha · integration · 2 worktrees")
        XCTAssertEqual(marked.text, "!  alpha · integration · 2 worktrees")
        XCTAssertEqual(clean.text.count, marked.text.count)
    }

    /// The strip sits above the whole list, so a line that does not name its
    /// repo reads as belonging to whichever group header it happens to float
    /// over — which is how a teamclaw round ended up looking like seahelm's.
    func testTheBannerNamesItsRepo() {
        let line = DashboardOverviewView.bannerLine(project: "teamclaw", status: nil,
                                                    needsAttention: false)
        XCTAssertTrue(line.text.contains("teamclaw · integration · not built yet"), line.text)
    }
}
