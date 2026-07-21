import XCTest
@testable import seahelm

final class WorktreeTitleResolverTests: XCTestCase {
    func testFallsBackToPromptWhenNoSummary() {
        let title = CabinTitleResolver.resolve(
            worktreePath: "/nonexistent/path",
            lastUserPrompt: "Fix the login bug",
            branch: "feature/login",
            sessionTitle: { _ in nil },
            taskDescription: { _ in nil }
        )
        XCTAssertEqual(title, "Fix the login bug")
    }

    func testPrefersSessionTitle() {
        let title = CabinTitleResolver.resolve(
            worktreePath: "/p",
            lastUserPrompt: "prompt",
            branch: "br",
            sessionTitle: { _ in "Session Title" },
            taskDescription: { _ in nil }
        )
        XCTAssertEqual(title, "Session Title")
    }

    func testFallsBackToBranchWhenEmpty() {
        let title = CabinTitleResolver.resolve(
            worktreePath: "/p",
            lastUserPrompt: "",
            branch: "feature/x",
            sessionTitle: { _ in nil },
            taskDescription: { _ in nil }
        )
        XCTAssertEqual(title, "feature/x")
    }

    func testPrefersTaskOverPromptAndBranch() {
        let title = CabinTitleResolver.resolve(
            worktreePath: "/p",
            lastUserPrompt: "some detected prompt",
            branch: "feature/x",
            sessionTitle: { _ in nil },
            taskDescription: { _ in "Implement dark mode" }
        )
        XCTAssertEqual(title, "Implement dark mode")
    }

    func testSummaryStillWinsOverTask() {
        let title = CabinTitleResolver.resolve(
            worktreePath: "/p",
            lastUserPrompt: "prompt",
            branch: "br",
            sessionTitle: { _ in "AI Summary" },
            taskDescription: { _ in "the task" }
        )
        XCTAssertEqual(title, "AI Summary")
    }

    func testFallsThroughEmptyTaskToPrompt() {
        let title = CabinTitleResolver.resolve(
            worktreePath: "/p",
            lastUserPrompt: "the prompt",
            branch: "br",
            sessionTitle: { _ in nil },
            taskDescription: { _ in "   " }
        )
        XCTAssertEqual(title, "the prompt")
    }
}
