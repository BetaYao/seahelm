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
        XCTAssertEqual(vc.selectedTabForTesting, .files)
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
        XCTAssertEqual(vc.mountedTabsForTesting.count, 2)

        vc.setWorktree("/tmp/wt-b")
        XCTAssertEqual(vc.mountedTabsForTesting, [.changes],
                       "only the freshly shown tab should be mounted after a worktree switch")
    }

    // MARK: - Changes: what is still to PR

    func testSectionsPutUncommittedFirstAndNameTheBase() {
        let branch = GitBranchChanges(
            basis: .mergeResult(baseRef: "origin/main"),
            files: [file("b.txt", .committed), file("a.txt", .unstaged), file("c.txt", .committed)],
            totalCount: 3
        )

        let sections = ChangesSummary.sections(for: branch)

        XCTAssertEqual(sections.map(\.title), ["Uncommitted · 1", "Not in main · 2"])
        XCTAssertEqual(sections.map { $0.files.map(\.path) }, [["a.txt"], ["b.txt", "c.txt"]])
    }

    func testSectionsAfterAMergedPRNameThePR() {
        let branch = GitBranchChanges(
            basis: .sinceMergedPR(MergedPRHead(number: 1487, headSHA: "7b4c04a8b"), baseRef: "origin/main"),
            files: [file("after.txt", .committed)],
            totalCount: 1
        )

        XCTAssertEqual(ChangesSummary.sections(for: branch).map(\.title), ["After #1487 · 1"])
        XCTAssertEqual(ChangesSummary.subtitle(for: branch), "1 file · since #1487")
    }

    func testAMergedBranchWithNothingLeftSaysSo() {
        let branch = GitBranchChanges(
            basis: .sinceMergedPR(MergedPRHead(number: 1487, headSHA: "7b4c04a8b"), baseRef: "origin/main"),
            files: [],
            totalCount: 0
        )

        XCTAssertEqual(ChangesSummary.subtitle(for: branch), "merged in #1487")
        XCTAssertEqual(ChangesSummary.emptyMessage(for: branch), "Nothing left to PR — everything here went in with #1487")
        XCTAssertTrue(ChangesSummary.sections(for: branch).isEmpty)
    }

    /// The answer is only as fresh as the last fetch, so a stale one is named.
    func testSubtitleNamesAStaleFetchOnly() {
        let now = Date()
        func branch(fetchedAgo: TimeInterval) -> GitBranchChanges {
            GitBranchChanges(
                basis: .mergeResult(baseRef: "origin/main"),
                files: [file("a.txt", .committed)],
                totalCount: 1,
                fetchedAt: now.addingTimeInterval(-fetchedAgo)
            )
        }

        XCTAssertEqual(ChangesSummary.subtitle(for: branch(fetchedAgo: 20 * 60), now: now), "1 file · vs main")
        XCTAssertEqual(ChangesSummary.subtitle(for: branch(fetchedAgo: 3 * 3600), now: now),
                       "1 file · vs main · fetched 3h ago")
    }

    func testTreeGroupsHoldEachSectionsDirectories() {
        let roots = ChangeTreeBuilder.build(sections: [
            ChangeSection(title: "Uncommitted · 1", files: [file("src/a.swift", .unstaged)]),
            ChangeSection(title: "Not in main · 1", files: [file("b.txt", .committed)]),
        ])

        XCTAssertEqual(roots.map(\.name), ["Uncommitted · 1", "Not in main · 1"])
        XCTAssertEqual(roots.map(\.isGroup), [true, true])
        XCTAssertEqual(roots[0].children.map(\.name), ["src"])
        XCTAssertEqual(roots[1].children.map(\.name), ["b.txt"])
    }

    private func file(_ path: String, _ stage: GitChangeStage) -> GitChangedFile {
        GitChangedFile(path: path, oldPath: nil, status: .modified, stage: stage)
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
}
