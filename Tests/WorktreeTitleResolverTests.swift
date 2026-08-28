import XCTest
@testable import seahelm

final class WorktreeTitleResolverTests: XCTestCase {
    func testFallsBackToPromptWhenNoSummary() {
        let title = WorktreeTitleResolver.resolve(
            worktreePath: "/nonexistent/path",
            lastUserPrompt: "Fix the login bug",
            branch: "feature/login",
            sessionTitle: { _ in nil },
            taskDescription: { _ in nil }
        )
        XCTAssertEqual(title, "Fix the login bug")
    }

    func testPrefersSessionTitle() {
        let title = WorktreeTitleResolver.resolve(
            worktreePath: "/p",
            lastUserPrompt: "prompt",
            branch: "br",
            sessionTitle: { _ in "Session Title" },
            taskDescription: { _ in nil }
        )
        XCTAssertEqual(title, "Session Title")
    }

    func testFallsBackToBranchWhenEmpty() {
        let title = WorktreeTitleResolver.resolve(
            worktreePath: "/p",
            lastUserPrompt: "",
            branch: "feature/x",
            sessionTitle: { _ in nil },
            taskDescription: { _ in nil }
        )
        XCTAssertEqual(title, "feature/x")
    }

    func testPrefersTaskOverPromptAndBranch() {
        let title = WorktreeTitleResolver.resolve(
            worktreePath: "/p",
            lastUserPrompt: "some detected prompt",
            branch: "feature/x",
            sessionTitle: { _ in nil },
            taskDescription: { _ in "Implement dark mode" }
        )
        XCTAssertEqual(title, "Implement dark mode")
    }

    func testSummaryStillWinsOverTask() {
        let title = WorktreeTitleResolver.resolve(
            worktreePath: "/p",
            lastUserPrompt: "prompt",
            branch: "br",
            sessionTitle: { _ in "AI Summary" },
            taskDescription: { _ in "the task" }
        )
        XCTAssertEqual(title, "AI Summary")
    }

    func testFallsThroughEmptyTaskToPrompt() {
        let title = WorktreeTitleResolver.resolve(
            worktreePath: "/p",
            lastUserPrompt: "the prompt",
            branch: "br",
            sessionTitle: { _ in nil },
            taskDescription: { _ in "   " }
        )
        XCTAssertEqual(title, "the prompt")
    }

    /// The integration checkout has no agent and no task, so every other source
    /// would end up describing a shell. Its own state wins outright.
    func testIntegrationStateOutranksEveryOtherSource() {
        let title = WorktreeTitleResolver.resolve(
            worktreePath: "/repo-worktrees/integration",
            lastUserPrompt: "a prompt",
            branch: "some-branch",
            integrationStatus: { _ in "integration · 3 worktrees" },
            sessionTitle: { _ in "a session summary" },
            taskDescription: { _ in "a task" }
        )
        XCTAssertEqual(title, "integration · 3 worktrees")
    }

    /// Every other worktree is unaffected — no status, no change in order.
    func testAbsentIntegrationStateChangesNothing() {
        let title = WorktreeTitleResolver.resolve(
            worktreePath: "/repo-worktrees/agent",
            lastUserPrompt: "a prompt",
            branch: "some-branch",
            integrationStatus: { _ in nil },
            sessionTitle: { _ in nil },
            taskDescription: { _ in "a task" }
        )
        XCTAssertEqual(title, "a task")
    }

    func testBlankIntegrationStateFallsThrough() {
        let title = WorktreeTitleResolver.resolve(
            worktreePath: "/repo-worktrees/integration",
            lastUserPrompt: "a prompt",
            branch: "some-branch",
            integrationStatus: { _ in "   " },
            sessionTitle: { _ in nil },
            taskDescription: { _ in nil }
        )
        XCTAssertEqual(title, "a prompt")
    }
}
