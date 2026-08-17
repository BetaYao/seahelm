import XCTest
@testable import seahelm

final class AgentTypeTests: XCTestCase {

    // MARK: - Launch command + suggest instruction injection

    // These all pass `agentYolo:` explicitly. The single-argument overload reads
    // the *user's real* ~/.config/seahelm/config.json, which made these tests
    // pass or fail depending on whether the machine happened to have YOLO mode
    // on — they flipped mid-session when the running app rewrote its config.

    func testClaudeLaunchInjectsSuggestInstruction() {
        let cmd = AgentType.claudeCode.launchCommand(withTask: "fix the bug", agentYolo: false)!
        XCTAssertTrue(cmd.hasPrefix("claude --append-system-prompt "))
        XCTAssertTrue(cmd.contains(StopHookResponder.sentinel))   // inline sentinel, not a Bash call
        XCTAssertTrue(cmd.hasSuffix("'fix the bug'"))   // task stays the positional arg
    }

    func testNonClaudeAgentNoInjection() {
        let cmd = AgentType.codex.launchCommand(withTask: "do x", agentYolo: false)!
        XCTAssertFalse(cmd.contains("--append-system-prompt"))
        XCTAssertEqual(cmd, "codex 'do x'")
    }

    func testEmptyTaskStillInjectsForClaude() {
        let cmd = AgentType.claudeCode.launchCommand(withTask: "  ", agentYolo: false)!
        XCTAssertTrue(cmd.contains("--append-system-prompt"))
        XCTAssertFalse(cmd.hasSuffix("''"))   // no empty positional task
    }

    func testYoloFlagIsAppendedWhenEnabled() {
        // The behaviour that used to leak in from the user's config — pinned
        // down deliberately instead.
        XCTAssertEqual(
            AgentType.codex.launchCommand(withTask: "do x", agentYolo: true),
            "codex --dangerously-bypass-approvals-and-sandbox 'do x'"
        )
        XCTAssertTrue(
            AgentType.claudeCode.launchCommand(withTask: "do x", agentYolo: true)!
                .hasPrefix("claude --dangerously-skip-permissions ")
        )
    }

    // MARK: - Pi agent

    func testPiIsAFirstClassAgent() {
        XCTAssertEqual(AgentType.pi.displayName, "Pi")
        XCTAssertEqual(AgentType.pi.launchCommand, "pi")
        XCTAssertTrue(AgentType.pi.isAIAgent)
        XCTAssertEqual(AgentType.pi.manifestId, "pi")
        XCTAssertEqual(AgentType.fromManifestId("pi"), .pi)
        // Pi uses a project-trust model, not a skip-permissions flag.
        XCTAssertNil(AgentType.pi.yoloFlag)
    }

    func testPiLaunchTakesTaskAsPositionalArg() {
        let cmd = AgentType.pi.launchCommand(withTask: "fix the bug", agentYolo: true)!
        XCTAssertEqual(cmd, "pi 'fix the bug'")   // no yolo flag, no system-prompt injection
    }

    // MARK: - Detection from terminal content

    func testDetectClaudeCode() {
        let result = AgentType.detect(fromLowercased: "claude code v1.2.3 press esc to interrupt")
        XCTAssertEqual(result, .claudeCode)
    }

    func testDetectCodex() {
        let result = AgentType.detect(fromLowercased: "codex> running task")
        XCTAssertEqual(result, .codex)
    }

    func testDetectOpenCode() {
        let result = AgentType.detect(fromLowercased: "opencode v0.5.0 ready")
        XCTAssertEqual(result, .openCode)
    }

    func testDetectGemini() {
        let result = AgentType.detect(fromLowercased: "gemini cli v2.0")
        XCTAssertEqual(result, .gemini)
    }

    func testDetectCline() {
        let result = AgentType.detect(fromLowercased: "cline> working on task")
        XCTAssertEqual(result, .cline)
    }

    func testDetectGoose() {
        let result = AgentType.detect(fromLowercased: "goose session started")
        XCTAssertEqual(result, .goose)
    }

    func testDetectAider() {
        let result = AgentType.detect(fromLowercased: "aider v0.40 main branch")
        XCTAssertEqual(result, .aider)
    }

    func testDetectUnknown() {
        let result = AgentType.detect(fromLowercased: "bash-5.2$ ls -la")
        XCTAssertEqual(result, .unknown)
    }

    func testDetectEmpty() {
        let result = AgentType.detect(fromLowercased: "")
        XCTAssertEqual(result, .unknown)
    }

    // MARK: - Specificity ordering

    func testOpenCodeBeforeCode() {
        // "opencode" should match .openCode, not something else containing "code"
        let result = AgentType.detect(fromLowercased: "opencode session active")
        XCTAssertEqual(result, .openCode)
    }

    // MARK: - Display names

    func testDisplayNames() {
        XCTAssertEqual(AgentType.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(AgentType.codex.displayName, "Codex")
        XCTAssertEqual(AgentType.openCode.displayName, "OpenCode")
        XCTAssertEqual(AgentType.unknown.displayName, "Unknown")
    }

    // MARK: - Shell command detection from command line

    func testDetectFromCommand_Brew() {
        XCTAssertEqual(AgentType.detect(fromCommand: "brew install ffmpeg"), .brew)
    }

    func testDetectFromCommand_Make() {
        XCTAssertEqual(AgentType.detect(fromCommand: "make build"), .make)
    }

    func testDetectFromCommand_Docker() {
        XCTAssertEqual(AgentType.detect(fromCommand: "docker run -it ubuntu"), .docker)
    }

    func testDetectFromCommand_Npm() {
        XCTAssertEqual(AgentType.detect(fromCommand: "npm run build"), .npm)
    }

    func testDetectFromCommand_Npx() {
        XCTAssertEqual(AgentType.detect(fromCommand: "npx create-react-app"), .npm)
    }

    func testDetectFromCommand_Python() {
        XCTAssertEqual(AgentType.detect(fromCommand: "python3 script.py"), .python)
    }

    func testDetectFromCommand_WithFullPath() {
        XCTAssertEqual(AgentType.detect(fromCommand: "/usr/local/bin/brew install ffmpeg"), .brew)
    }

    func testDetectFromCommand_WithEnvPrefix() {
        XCTAssertEqual(AgentType.detect(fromCommand: "ENV=val make build"), .make)
    }

    func testDetectFromCommand_UnknownCommand() {
        XCTAssertEqual(AgentType.detect(fromCommand: "myapp --flag"), .shellCommand)
    }

    func testDetectFromCommand_EmptyString() {
        XCTAssertEqual(AgentType.detect(fromCommand: ""), .unknown)
    }

    func testDetectFromCommand_Btop() {
        XCTAssertEqual(AgentType.detect(fromCommand: "btop"), .btop)
    }

    func testDetectFromCommand_Cargo() {
        XCTAssertEqual(AgentType.detect(fromCommand: "cargo build --release"), .cargo)
    }

    // MARK: - isAIAgent / isShellTask

    func testIsAIAgent() {
        XCTAssertTrue(AgentType.claudeCode.isAIAgent)
        XCTAssertTrue(AgentType.codex.isAIAgent)
        XCTAssertFalse(AgentType.brew.isAIAgent)
        XCTAssertFalse(AgentType.shellCommand.isAIAgent)
        XCTAssertFalse(AgentType.unknown.isAIAgent)
    }

    func testIsShellTask() {
        XCTAssertTrue(AgentType.brew.isShellTask)
        XCTAssertTrue(AgentType.shellCommand.isShellTask)
        XCTAssertFalse(AgentType.claudeCode.isShellTask)
        XCTAssertFalse(AgentType.unknown.isShellTask)
    }

    // MARK: - Shell task display names

    func testShellDisplayNames() {
        XCTAssertEqual(AgentType.brew.displayName, "Homebrew")
        XCTAssertEqual(AgentType.btop.displayName, "btop")
        XCTAssertEqual(AgentType.shellCommand.displayName, "Shell")
    }

    // MARK: - launchCommand(withTask:)

    // Use codex here: it gets no system-prompt injection, so the exact composed
    // string is stable. Claude's injection is covered above.
    func testLaunchCommandWithTaskComposesPositionalPrompt() {
        XCTAssertEqual(
            AgentType.codex.launchCommand(withTask: "add tests", agentYolo: false),
            "codex 'add tests'"
        )
    }

    func testLaunchCommandWithEmptyTaskReturnsBareCommand() {
        XCTAssertEqual(AgentType.codex.launchCommand(withTask: "", agentYolo: false), "codex")
        XCTAssertEqual(AgentType.codex.launchCommand(withTask: "   ", agentYolo: false), "codex")
    }

    func testLaunchCommandWithTaskEscapesQuotes() {
        XCTAssertEqual(
            AgentType.codex.launchCommand(withTask: "can't stop", agentYolo: false),
            "codex 'can'\\''t stop'"
        )
    }

    func testLaunchCommandWithTaskNilForNonAIPane() {
        XCTAssertNil(AgentType.npm.launchCommand(withTask: "anything", agentYolo: false))
        XCTAssertNil(AgentType.shellCommand.launchCommand(withTask: "anything", agentYolo: false))
    }
}
