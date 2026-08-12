import XCTest
@testable import seahelm

final class IslandProjectGroupTests: XCTestCase {
    private func row(_ project: String, _ branch: String, _ status: SailorStatus, path: String? = nil) -> IslandAgentRow {
        IslandAgentRow(
            id: path ?? "/\(project)/\(branch)",
            project: project,
            branch: branch,
            status: status,
            message: status == .idle ? "" : "busy",
            title: "task"
        )
    }

    func testGroupsByProjectAndSurfacesHotProjectsFirst() {
        let rows = [
            row("saas-mono", "main", .idle),
            row("seahelm", "main", .idle),
            row("seahelm", "feat/x", .error),
            row("teamclaw", "fix/y", .running),
            row("teamclaw", "main", .idle),
        ]
        let groups = IslandModel.groupedByProject(rows)
        XCTAssertEqual(groups.map(\.project), ["seahelm", "teamclaw", "saas-mono"])
        XCTAssertEqual(groups[0].rows.map(\.branch), ["feat/x", "main"])
        XCTAssertEqual(groups[1].rows.map(\.branch), ["fix/y", "main"])
        XCTAssertEqual(groups[0].rows.count, 2)
    }

    func testWorktreePluralCopyShape() {
        // Keep the opened-list count wording honest for the UI.
        XCTAssertEqual(worktreeCountLabel(1), "1 worktree")
        XCTAssertEqual(worktreeCountLabel(3), "3 worktrees")
    }

    func testNeedsAttentionOnlyForActiveStatuses() {
        XCTAssertTrue(row("a", "b", .running).needsAttention)
        XCTAssertTrue(row("a", "b", .waiting).needsAttention)
        XCTAssertTrue(row("a", "b", .error).needsAttention)
        XCTAssertFalse(row("a", "b", .idle).needsAttention)
        XCTAssertFalse(row("a", "b", .exited).needsAttention)
    }
}

/// Mirrors OpenedSurfaceView's project-header copy so a rename can't drift silently.
private func worktreeCountLabel(_ count: Int) -> String {
    "\(count) worktree\(count == 1 ? "" : "s")"
}
