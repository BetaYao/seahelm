import XCTest
@testable import seahelm

final class MiniCardViewTests: XCTestCase {
    func testConfigureSetsTitleAndRepoWorktree() {
        let card = MiniCardView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        card.configure(
            id: "t1", project: "teamclaw-next", thread: "test-trsyt",
            status: "running", lastMessage: "ignored",
            lastUserPrompt: "Why are classics unread?",
            totalDuration: "120", roundDuration: "30"
        )
        XCTAssertEqual(card.agentId, "t1")
        XCTAssertEqual(card.titleTextForTesting, "Why are classics unread?")
        // Repo name lives in the colored badge; the worktree branch in the line label.
        XCTAssertEqual(card.repoBadgeTextForTesting, "teamclaw-next")
        XCTAssertTrue(card.repoWorktreeTextForTesting.contains("test-trsyt"))
        XCTAssertFalse(card.repoWorktreeTextForTesting.contains("teamclaw-next"))
    }

    func testRepoColorIsStableAndVariesByRepo() {
        XCTAssertEqual(MiniCardView.repoColor(for: "repo-a"), MiniCardView.repoColor(for: "repo-a"))
        // Two repos that hash into different palette slots get different colors.
        XCTAssertNotEqual(MiniCardView.repoColor(for: "seahelm"), MiniCardView.repoColor(for: "teamclaw-next"))
    }

    func testTitleFallsBackToProject() {
        let card = MiniCardView(frame: .zero)
        card.configure(
            id: "t2", project: "repo", thread: "wt",
            status: "idle", lastMessage: "",
            lastUserPrompt: "",
            totalDuration: "0", roundDuration: "0"
        )
        XCTAssertEqual(card.titleTextForTesting, "repo")
    }
}
