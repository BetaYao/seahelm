import XCTest
@testable import seahelm

final class StatusDetectorTests: XCTestCase {
    let detector = StatusDetector()

    // MARK: - Process Status Priority

    func testProcessExited_OverridesEverything() {
        let result = detector.detect(
            processStatus: .exited,
            shellInfo: ShellPhaseInfo(phase: .running, lastExitCode: nil),
            content: "to interrupt",  // would match Running
            agentDef: AgentDetectConfig.default.agents.first
        )
        XCTAssertEqual(result, .exited)
    }

    func testProcessError_OverridesEverything() {
        let result = detector.detect(
            processStatus: .error,
            shellInfo: ShellPhaseInfo(phase: .input, lastExitCode: nil),
            content: "",
            agentDef: nil
        )
        XCTAssertEqual(result, .error)
    }

    // MARK: - Shell Phase Detection

    func testShellPhase_Running() {
        let result = detector.detect(
            processStatus: .running,
            shellInfo: ShellPhaseInfo(phase: .running, lastExitCode: nil),
            content: "",
            agentDef: nil
        )
        XCTAssertEqual(result, .running)
    }

    func testShellPhase_Input_IsIdle() {
        let result = detector.detect(
            processStatus: .running,
            shellInfo: ShellPhaseInfo(phase: .input, lastExitCode: nil),
            content: "",
            agentDef: nil
        )
        XCTAssertEqual(result, .idle)
    }

    func testShellPhase_Prompt_IsIdle() {
        let result = detector.detect(
            processStatus: .running,
            shellInfo: ShellPhaseInfo(phase: .prompt, lastExitCode: nil),
            content: "",
            agentDef: nil
        )
        XCTAssertEqual(result, .idle)
    }

    func testShellPhase_Output_ExitZero_IsIdle() {
        let result = detector.detect(
            processStatus: .running,
            shellInfo: ShellPhaseInfo(phase: .output, lastExitCode: 0),
            content: "",
            agentDef: nil
        )
        XCTAssertEqual(result, .idle)
    }

    func testShellPhase_Output_ExitNonZero_IsError() {
        let result = detector.detect(
            processStatus: .running,
            shellInfo: ShellPhaseInfo(phase: .output, lastExitCode: 1),
            content: "",
            agentDef: nil
        )
        XCTAssertEqual(result, .error)
    }

    // MARK: - Text Pattern Fallback

    func testTextPattern_ClaudeRunning() {
        let claude = AgentDetectConfig.default.agents.first!
        let result = detector.detect(
            processStatus: .running,
            shellInfo: nil,
            content: "Press Escape to interrupt",
            agentDef: claude
        )
        XCTAssertEqual(result, .running)
    }

    func testTextPattern_ClaudeWaiting() {
        let claude = AgentDetectConfig.default.agents.first!
        let result = detector.detect(
            processStatus: .running,
            shellInfo: nil,
            content: "Do you want to proceed?",
            agentDef: claude
        )
        XCTAssertEqual(result, .waiting)
    }

    func testTextPattern_ClaudeError() {
        let claude = AgentDetectConfig.default.agents.first!
        let result = detector.detect(
            processStatus: .running,
            shellInfo: nil,
            content: "ERROR: something went wrong",
            agentDef: claude
        )
        XCTAssertEqual(result, .error)
    }

    func testTextPattern_ClaudeDefaultIdle() {
        let claude = AgentDetectConfig.default.agents.first!
        let result = detector.detect(
            processStatus: .running,
            shellInfo: nil,
            content: "some random output",
            agentDef: claude
        )
        XCTAssertEqual(result, .idle)
    }

    func testTextPattern_ClaudeTaskProgressThinkingIsRunning() throws {
        let claude = try XCTUnwrap(AgentDetectConfig.default.agents.first { $0.name == "claude" })
        let content = """
        superpowers:code-reviewer(Code quality review Task 1)
        |_ Done (18 tool uses * 61.8k tokens * 1m 15s)

        * Task 2: Add insert_session_from_supabase to SessionManager... (thinking)
          - Task 2: Add insert_session_from_supabase to SessionManager
          - Task 3: Wire fetch+insert into apply_start_runtime
        """

        let result = detector.detect(
            processStatus: .running,
            shellInfo: nil,
            content: content,
            agentDef: claude
        )

        XCTAssertEqual(result, .running)
    }

    func testTextPattern_ClaudeTaskTransitionIsRunning() throws {
        let claude = try XCTUnwrap(AgentDetectConfig.default.agents.first { $0.name == "claude" })
        let content = "Task 1 approved. Moving to Task 2."

        let result = detector.detect(
            processStatus: .running,
            shellInfo: nil,
            content: content,
            agentDef: claude
        )

        XCTAssertEqual(result, .running)
    }

    func testTextPattern_CodexApprovalPromptIsWaiting() throws {
        let codex = try XCTUnwrap(AgentDetectConfig.default.agents.first { $0.name == "codex" })
        let content = """
        Would you like to run the following command?

        Reason: Allow activating the current Seahelm Tauri smoke window by pid?

        $ osascript -e 'tell application "System Events" to set frontmost of first process whose unix id is 51869 to true'

        1. Yes, proceed (y)
        2. Yes, and don't ask again for commands that start with ...
        3. No, and tell Codex what to do differently (esc)
        """

        let result = detector.detect(
            processStatus: .running,
            shellInfo: nil,
            content: content,
            agentDef: codex
        )

        XCTAssertEqual(result, .waiting)
    }

    func testTextPattern_CodexTaskProgressThinkingIsRunning() throws {
        let codex = try XCTUnwrap(AgentDetectConfig.default.agents.first { $0.name == "codex" })
        let content = """
        Agent(Implement Task 2: insert_session_from_supabase)
        |_ Done (27 tool uses * 65.0k tokens * 3m 5s)

        * Task 2: Add insert_session_from_supabase to SessionManager... (thinking)
          - Task 2: Add insert_session_from_supabase to SessionManager
          - Task 3: Wire fetch+insert into apply_start_runtime
        """

        let result = detector.detect(
            processStatus: .running,
            shellInfo: nil,
            content: content,
            agentDef: codex
        )

        XCTAssertEqual(result, .running)
    }

    func testTextPattern_CodexTaskTransitionIsRunning() throws {
        let codex = try XCTUnwrap(AgentDetectConfig.default.agents.first { $0.name == "codex" })
        let content = "Task 1 approved. Moving to Task 2."

        let result = detector.detect(
            processStatus: .running,
            shellInfo: nil,
            content: content,
            agentDef: codex
        )

        XCTAssertEqual(result, .running)
    }

    func testNoShellInfo_NoAgent_ReturnsUnknown() {
        let result = detector.detect(
            processStatus: .running,
            shellInfo: nil,
            content: "",
            agentDef: nil
        )
        XCTAssertEqual(result, .unknown)
    }
}

// MARK: - DebouncedStatusTracker Tests

final class DebouncedStatusTrackerTests: XCTestCase {
    func testInitialStatusIsUnknown() {
        let tracker = DebouncedStatusTracker()
        XCTAssertEqual(tracker.currentStatus, .unknown)
    }

    func testUpdate_ChangesStatus() {
        let tracker = DebouncedStatusTracker()
        let changed = tracker.update(status: .running)
        XCTAssertTrue(changed)
        XCTAssertEqual(tracker.currentStatus, .running)
    }

    func testUpdate_SameStatus_NoChange() {
        let tracker = DebouncedStatusTracker()
        tracker.update(status: .running)
        let changed = tracker.update(status: .running)
        XCTAssertFalse(changed)
    }

    func testUpdate_Unknown_PreservesCurrent() {
        let tracker = DebouncedStatusTracker()
        tracker.update(status: .running)
        let changed = tracker.update(status: .unknown)
        XCTAssertFalse(changed)
        XCTAssertEqual(tracker.currentStatus, .running)
    }

    func testForceStatus() {
        let tracker = DebouncedStatusTracker()
        tracker.forceStatus(.error)
        XCTAssertEqual(tracker.currentStatus, .error)
    }

    func testReset() {
        let tracker = DebouncedStatusTracker()
        tracker.update(status: .running)
        tracker.reset()
        XCTAssertEqual(tracker.currentStatus, .unknown)
    }
}

// MARK: - AgentStatus Priority Tests

final class AgentStatusTests: XCTestCase {
    func testPriorityOrder() {
        XCTAssertGreaterThan(AgentStatus.error.priority, AgentStatus.exited.priority)
        XCTAssertGreaterThan(AgentStatus.exited.priority, AgentStatus.waiting.priority)
        XCTAssertGreaterThan(AgentStatus.waiting.priority, AgentStatus.running.priority)
        XCTAssertGreaterThan(AgentStatus.running.priority, AgentStatus.idle.priority)
        XCTAssertGreaterThan(AgentStatus.idle.priority, AgentStatus.unknown.priority)
    }

    func testHighestPriority() {
        let result = AgentStatus.highestPriority([.idle, .running, .unknown])
        XCTAssertEqual(result, .running)
    }

    func testHighestPriority_Empty() {
        let result = AgentStatus.highestPriority([])
        XCTAssertEqual(result, .unknown)
    }

    func testIsUrgent() {
        XCTAssertTrue(AgentStatus.error.isUrgent)
        XCTAssertTrue(AgentStatus.waiting.isUrgent)
        XCTAssertFalse(AgentStatus.running.isUrgent)
        XCTAssertFalse(AgentStatus.idle.isUrgent)
    }

    func testIsActive() {
        XCTAssertTrue(AgentStatus.running.isActive)
        XCTAssertTrue(AgentStatus.waiting.isActive)
        XCTAssertFalse(AgentStatus.idle.isActive)
        XCTAssertFalse(AgentStatus.error.isActive)
    }
}

// MARK: - AgentDef Detection Tests

final class AgentDefTests: XCTestCase {
    func testDetectStatus_FirstMatchWins() {
        let agent = AgentDef(
            name: "test",
            rules: [
                AgentRule(status: "Running", patterns: ["working"]),
                AgentRule(status: "Error", patterns: ["working error"]),
            ],
            defaultStatus: "Idle",
            messageSkipPatterns: []
        )
        // "working" matches first rule
        let result = agent.detectStatus(from: "I am working error on something")
        XCTAssertEqual(result, .running)
    }

    func testDetectStatus_CaseInsensitive() {
        let agent = AgentDetectConfig.default.agents.first!
        let result = agent.detectStatus(from: "TO INTERRUPT")
        XCTAssertEqual(result, .running)
    }

    func testDetectStatus_DefaultStatus() {
        let agent = AgentDetectConfig.default.agents.first!
        let result = agent.detectStatus(from: "nothing special here")
        XCTAssertEqual(result, .idle)
    }

    func testExtractLastMessage_SkipsChrome() {
        let agent = AgentDef(
            name: "test",
            rules: [],
            defaultStatus: "Idle",
            messageSkipPatterns: ["skip this"]
        )
        let content = "real message\n───────────\nskip this line\n"
        let msg = agent.extractLastMessage(from: content, maxLen: 100)
        XCTAssertEqual(msg, "real message")
    }

    func testExtractLastMessage_Truncation() {
        let agent = AgentDef(name: "test", rules: [], defaultStatus: "Idle", messageSkipPatterns: [])
        let content = "This is a very long message that should be truncated"
        let msg = agent.extractLastMessage(from: content, maxLen: 20)
        XCTAssertTrue(msg.count <= 20)
        XCTAssertTrue(msg.hasSuffix("..."))
    }
}
