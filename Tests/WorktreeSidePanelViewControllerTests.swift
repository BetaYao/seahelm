// Tests/WorktreeSidePanelViewControllerTests.swift
import XCTest
import AppKit
@testable import seahelm

final class WorktreeSidePanelViewControllerTests: XCTestCase {
    private func makeVC(worktreePath: String?) -> WorktreeSidePanelViewController {
        WorktreeSidePanelViewController(worktreePath: worktreePath)
    }

    func testInitHoldsWorktreePath() {
        let vc = makeVC(worktreePath: "/tmp/wt-a")
        vc.loadViewIfNeeded()
        XCTAssertEqual(vc.worktreePathForTesting, "/tmp/wt-a")
        XCTAssertEqual(vc.selectedTabForTesting, .firstMate)
    }

    func testSetWorktreeUpdatesHeldPath() {
        let vc = makeVC(worktreePath: "/tmp/wt-a")
        vc.loadViewIfNeeded()
        vc.setWorktree("/tmp/wt-b")
        XCTAssertEqual(vc.worktreePathForTesting, "/tmp/wt-b")
    }

    // MARK: - Tabs stay mounted across switches

    /// The point of keeping tabs mounted: leaving a tab must not tear its content
    /// down, or scroll position / selection / the file tree's FSEvents watcher all
    /// die with it.
    func testLeavingATabKeepsItMountedButHidden() {
        let vc = makeVC(worktreePath: "/tmp/wt-a")
        vc.loadViewIfNeeded()
        vc.selectTab(.files)
        let filesContainer = vc.containerForTesting(.files)
        XCTAssertNotNil(filesContainer)

        vc.selectTab(.changes)
        XCTAssertTrue(vc.mountedTabsForTesting.contains(.files), "files must stay mounted")
        XCTAssertTrue(filesContainer?.isHidden == true, "…but hidden")
        XCTAssertTrue(vc.containerForTesting(.changes)?.isHidden == false)
    }

    func testReturningToATabReusesTheSameContainer() {
        let vc = makeVC(worktreePath: "/tmp/wt-a")
        vc.loadViewIfNeeded()
        vc.selectTab(.files)
        let first = vc.containerForTesting(.files)
        vc.selectTab(.changes)
        vc.selectTab(.files)
        XCTAssertTrue(first === vc.containerForTesting(.files),
                      "returning to a tab must reuse its view, not rebuild it")
        XCTAssertTrue(first?.isHidden == false)
    }

    /// Mounted state belongs to a worktree — switching worktrees must discard it,
    /// otherwise a tab would show another worktree's files.
    func testChangingWorktreeDiscardsMountedTabs() {
        let vc = makeVC(worktreePath: "/tmp/wt-a")
        vc.loadViewIfNeeded()
        vc.selectTab(.files)
        vc.selectTab(.changes)
        XCTAssertEqual(vc.mountedTabsForTesting.count, 3)

        vc.setWorktree("/tmp/wt-b")
        XCTAssertEqual(vc.mountedTabsForTesting, [.changes],
                       "only the freshly shown tab should be mounted after a worktree switch")
    }

    func testChangeTreeBuilderGroupsFilesByDirectory() {
        let files = [
            GitChangedFile(path: "Sources/App/Main.swift", oldPath: nil, status: .modified, stage: .unstaged),
            GitChangedFile(path: "Sources/Core/Config.swift", oldPath: nil, status: .added, stage: .unstaged),
            GitChangedFile(path: "README.md", oldPath: nil, status: .modified, stage: .unstaged),
        ]

        let roots = ChangeTreeBuilder.build(from: files)
        XCTAssertEqual(roots.map(\.name), ["Sources", "README.md"])
        XCTAssertEqual(roots.first?.children.map(\.name), ["App", "Core"])
        XCTAssertEqual(roots.first?.children.first?.children.map(\.name), ["Main.swift"])
        XCTAssertEqual(roots.last?.entry?.path, "README.md")
    }

    // MARK: - Integration composition

    private func makeIntegrationVC(_ state: IntegrationPanelState?) -> WorktreeSidePanelViewController {
        WorktreeSidePanelViewController(
            worktreePath: "/repo-worktrees/integration",
            initialTab: .changes,
            integrationState: { _ in state }
        )
    }

    /// The Changes tab runs its `git diff` off the main thread, so the strip
    /// only exists once that lands.
    private func compositionLines(_ vc: WorktreeSidePanelViewController) -> [String] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if !vc.integrationCompositionLinesForTesting.isEmpty { break }
        }
        return vc.integrationCompositionLinesForTesting
    }

    /// An integration checkout's diff is several worktrees folded together, so
    /// the file list alone never says whose work it is.
    func testCompositionNamesWhatWentInAndWhatDidNot() {
        let vc = makeIntegrationVC(IntegrationPanelState(
            line: "integration · 2 worktrees",
            included: ["agentA", "agentB"],
            excluded: [.init(label: "agentC", paths: ["shared.txt"])],
            conflictedPaths: [],
            isHeld: false
        ))
        vc.loadViewIfNeeded()
        vc.selectTab(.changes)

        XCTAssertEqual(compositionLines(vc), [
            "in: agentA, agentB",
            "excluded: agentC · shared.txt",
        ])
    }

    /// A held round is the one state a user has to act on, so it says how.
    func testCompositionSurfacesAHeldCheckout() {
        let vc = makeIntegrationVC(IntegrationPanelState(
            line: "integration · 1 worktree · pending",
            included: ["agentA"],
            excluded: [],
            conflictedPaths: [],
            isHeld: true
        ))
        vc.loadViewIfNeeded()
        vc.selectTab(.changes)

        XCTAssertEqual(compositionLines(vc), [
            "in: agentA",
            "not checked out — local edits here · /integrate force",
        ])
    }

    func testCompositionReportsConflictMarkers() {
        let vc = makeIntegrationVC(IntegrationPanelState(
            line: "integration · 2 worktrees",
            included: ["agentA", "agentC"],
            excluded: [],
            conflictedPaths: ["shared.txt"],
            isHeld: false
        ))
        vc.loadViewIfNeeded()
        vc.selectTab(.changes)

        let lines = compositionLines(vc)
        XCTAssertTrue(lines.contains("conflict markers: shared.txt"), "\(lines)")
    }

    /// Every other worktree's Changes tab is untouched.
    func testOrdinaryWorktreeShowsNoComposition() {
        let vc = makeIntegrationVC(nil)
        vc.loadViewIfNeeded()
        vc.selectTab(.changes)
        XCTAssertEqual(compositionLines(vc), [])
    }

    // MARK: - state store round trip

    func testStoreDecodesStructuredStateAndLegacyPlainText() {
        let state = IntegrationPanelState(line: "integration · 3 worktrees", included: ["a"],
                                          excluded: [], conflictedPaths: [], isHeld: false)
        let encoded = String(data: try! JSONEncoder().encode(state), encoding: .utf8)!
        XCTAssertEqual(IntegrationStatusStore.decode(encoded), state)
        // Entries written before the store held structured state must not blank
        // the card on upgrade.
        XCTAssertNil(IntegrationStatusStore.decode("integration · 3 worktrees"))
    }
}
