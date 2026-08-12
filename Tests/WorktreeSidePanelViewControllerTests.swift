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
}
