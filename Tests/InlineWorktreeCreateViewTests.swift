import XCTest
@testable import seahelm

final class InlineWorktreeCreateViewTests: XCTestCase {
    func testSubmitInvokesCallbackWithTaskDescriptionAndValues() {
        let view = InlineWorktreeCreateView()
        view.configure(repoPaths: ["/Users/me/repoA", "/Users/me/repoB"])
        var captured: (String, String, AgentType, Bool)?
        view.onCreate = { task, repo, agentType, reuse in captured = (task, repo, agentType, reuse) }

        view.setNameForTesting("Fix flaky login redirect")
        view.setReuseEnvForTesting(true)
        view.submitForTesting()

        XCTAssertEqual(captured?.0, "Fix flaky login redirect")
        XCTAssertEqual(captured?.1, "/Users/me/repoA")
        XCTAssertEqual(captured?.2, .claudeCode)
        XCTAssertEqual(captured?.3, true)
    }

    func testBlankNameDoesNotSubmit() {
        let view = InlineWorktreeCreateView()
        view.configure(repoPaths: ["/r"])
        var called = false
        view.onCreate = { _, _, _, _ in called = true }
        view.setNameForTesting("   ")
        view.submitForTesting()
        XCTAssertFalse(called)
    }

    func testExpandedStateTogglesOnFocus() {
        let view = InlineWorktreeCreateView()
        view.configure(repoPaths: ["/r"])
        XCTAssertFalse(view.isExpandedForTesting)
        view.setExpandedForTesting(true)
        XCTAssertTrue(view.isExpandedForTesting)
    }

    func testCollapsedStateUsesCompactAgentIconPicker() {
        let view = InlineWorktreeCreateView()
        view.configure(repoPaths: ["/r"])

        XCTAssertEqual(view.preferredHeightForTesting, 84)
        XCTAssertTrue(view.agentChipShowsIconForTesting)
        XCTAssertEqual(view.agentChipTitleForTesting, "")
        XCTAssertEqual(view.agentChipBorderWidthForTesting, 0)
        XCTAssertEqual(view.repoChipPreferredHeightForTesting, 24)
        XCTAssertEqual(view.controlRowBottomPaddingForTesting, 10)
    }

    // MARK: - Agent chip cycling (Phase 6)

    func testCycleAgentForwardAdvancesThroughChoices() {
        let view = InlineWorktreeCreateView()
        view.configure(repoPaths: ["/r"])
        let choices = InlineWorktreeCreateView.agentChoices
        XCTAssertGreaterThan(choices.count, 1, "need >1 AI agent for a meaningful cycle test")

        // Start pinned to the first choice, then step forward one at a time.
        view.selectedAgentType = choices[0]
        for i in 1..<choices.count {
            view.cycleAgent(1)
            XCTAssertEqual(view.selectedAgentType, choices[i])
        }
    }

    func testCycleAgentForwardWrapsAtEnd() {
        let view = InlineWorktreeCreateView()
        view.configure(repoPaths: ["/r"])
        let choices = InlineWorktreeCreateView.agentChoices
        view.selectedAgentType = choices[choices.count - 1]
        view.cycleAgent(1)
        XCTAssertEqual(view.selectedAgentType, choices[0])
    }

    func testCycleAgentBackwardWrapsAtStart() {
        let view = InlineWorktreeCreateView()
        view.configure(repoPaths: ["/r"])
        let choices = InlineWorktreeCreateView.agentChoices
        view.selectedAgentType = choices[0]
        view.cycleAgent(-1)
        XCTAssertEqual(view.selectedAgentType, choices[choices.count - 1])
    }

    // MARK: - Repo chip cycling (Phase 6)

    func testCycleRepoForwardWrapsAround() {
        let view = InlineWorktreeCreateView()
        view.configure(repoPaths: ["/a", "/b", "/c"])
        XCTAssertEqual(view.selectedRepoPath, "/a")
        view.cycleRepo(1)
        XCTAssertEqual(view.selectedRepoPath, "/b")
        view.cycleRepo(1)
        XCTAssertEqual(view.selectedRepoPath, "/c")
        view.cycleRepo(1)  // wraps back to start
        XCTAssertEqual(view.selectedRepoPath, "/a")
    }

    func testCycleRepoBackwardWrapsAtStart() {
        let view = InlineWorktreeCreateView()
        view.configure(repoPaths: ["/a", "/b", "/c"])
        XCTAssertEqual(view.selectedRepoPath, "/a")
        view.cycleRepo(-1)  // wraps to last
        XCTAssertEqual(view.selectedRepoPath, "/c")
    }

    func testFocusRequestsTallerInputHeightThenRestoresOnBlur() {
        let view = InlineWorktreeCreateView()
        view.configure(repoPaths: ["/r"])
        var requestedHeights: [CGFloat] = []
        view.onPreferredHeightChange = { height, _ in requestedHeights.append(height) }

        let collapsedHeight = view.preferredHeightForTesting
        view.controlTextDidBeginEditing(Notification(name: NSText.didBeginEditingNotification))
        let expandedHeight = view.preferredHeightForTesting
        view.controlTextDidEndEditing(Notification(name: NSText.didEndEditingNotification))

        XCTAssertGreaterThan(expandedHeight, collapsedHeight)
        XCTAssertEqual(expandedHeight, 120)
        XCTAssertEqual(requestedHeights, [expandedHeight, collapsedHeight])
        XCTAssertFalse(view.isExpandedForTesting)
    }
}
