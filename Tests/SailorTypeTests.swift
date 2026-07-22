import XCTest
@testable import seahelm

final class SailorTypeTests: XCTestCase {

    // MARK: - Launch command + suggest instruction injection

    func testClaudeLaunchInjectsSuggestInstruction() {
        let cmd = SailorType.claudeCode.launchCommand(withTask: "fix the bug")!
        XCTAssertTrue(cmd.hasPrefix("claude --append-system-prompt "))
        XCTAssertTrue(cmd.contains(StopHookResponder.sentinel))   // inline sentinel, not a Bash call
        XCTAssertTrue(cmd.hasSuffix("'fix the bug'"))   // task stays the positional arg
    }

    func testNonClaudeAgentNoInjection() {
        let cmd = SailorType.codex.launchCommand(withTask: "do x")!
        XCTAssertFalse(cmd.contains("--append-system-prompt"))
        XCTAssertEqual(cmd, "codex 'do x'")
    }

    func testEmptyTaskStillInjectsForClaude() {
        let cmd = SailorType.claudeCode.launchCommand(withTask: "  ")!
        XCTAssertTrue(cmd.contains("--append-system-prompt"))
        XCTAssertFalse(cmd.hasSuffix("''"))   // no empty positional task
    }

    // MARK: - Detection from terminal content

    func testDetectClaudeCode() {
        let result = SailorType.detect(fromLowercased: "claude code v1.2.3 press esc to interrupt")
        XCTAssertEqual(result, .claudeCode)
    }

    func testDetectCodex() {
        let result = SailorType.detect(fromLowercased: "codex> running task")
        XCTAssertEqual(result, .codex)
    }

    func testDetectOpenCode() {
        let result = SailorType.detect(fromLowercased: "opencode v0.5.0 ready")
        XCTAssertEqual(result, .openCode)
    }

    func testDetectGemini() {
        let result = SailorType.detect(fromLowercased: "gemini cli v2.0")
        XCTAssertEqual(result, .gemini)
    }

    func testDetectCline() {
        let result = SailorType.detect(fromLowercased: "cline> working on task")
        XCTAssertEqual(result, .cline)
    }

    func testDetectGoose() {
        let result = SailorType.detect(fromLowercased: "goose session started")
        XCTAssertEqual(result, .goose)
    }

    func testDetectAider() {
        let result = SailorType.detect(fromLowercased: "aider v0.40 main branch")
        XCTAssertEqual(result, .aider)
    }

    func testDetectUnknown() {
        let result = SailorType.detect(fromLowercased: "bash-5.2$ ls -la")
        XCTAssertEqual(result, .unknown)
    }

    func testDetectEmpty() {
        let result = SailorType.detect(fromLowercased: "")
        XCTAssertEqual(result, .unknown)
    }

    // MARK: - Specificity ordering

    func testOpenCodeBeforeCode() {
        // "opencode" should match .openCode, not something else containing "code"
        let result = SailorType.detect(fromLowercased: "opencode session active")
        XCTAssertEqual(result, .openCode)
    }

    // MARK: - Display names

    func testDisplayNames() {
        XCTAssertEqual(SailorType.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(SailorType.codex.displayName, "Codex")
        XCTAssertEqual(SailorType.openCode.displayName, "OpenCode")
        XCTAssertEqual(SailorType.unknown.displayName, "Unknown")
    }

    // MARK: - Shell command detection from command line

    func testDetectFromCommand_Brew() {
        XCTAssertEqual(SailorType.detect(fromCommand: "brew install ffmpeg"), .brew)
    }

    func testDetectFromCommand_Make() {
        XCTAssertEqual(SailorType.detect(fromCommand: "make build"), .make)
    }

    func testDetectFromCommand_Docker() {
        XCTAssertEqual(SailorType.detect(fromCommand: "docker run -it ubuntu"), .docker)
    }

    func testDetectFromCommand_Npm() {
        XCTAssertEqual(SailorType.detect(fromCommand: "npm run build"), .npm)
    }

    func testDetectFromCommand_Npx() {
        XCTAssertEqual(SailorType.detect(fromCommand: "npx create-react-app"), .npm)
    }

    func testDetectFromCommand_Python() {
        XCTAssertEqual(SailorType.detect(fromCommand: "python3 script.py"), .python)
    }

    func testDetectFromCommand_WithFullPath() {
        XCTAssertEqual(SailorType.detect(fromCommand: "/usr/local/bin/brew install ffmpeg"), .brew)
    }

    func testDetectFromCommand_WithEnvPrefix() {
        XCTAssertEqual(SailorType.detect(fromCommand: "ENV=val make build"), .make)
    }

    func testDetectFromCommand_UnknownCommand() {
        XCTAssertEqual(SailorType.detect(fromCommand: "myapp --flag"), .shellCommand)
    }

    func testDetectFromCommand_EmptyString() {
        XCTAssertEqual(SailorType.detect(fromCommand: ""), .unknown)
    }

    func testDetectFromCommand_Btop() {
        XCTAssertEqual(SailorType.detect(fromCommand: "btop"), .btop)
    }

    func testDetectFromCommand_Cargo() {
        XCTAssertEqual(SailorType.detect(fromCommand: "cargo build --release"), .cargo)
    }

    // MARK: - isAIAgent / isShellTask

    func testIsAIAgent() {
        XCTAssertTrue(SailorType.claudeCode.isAIAgent)
        XCTAssertTrue(SailorType.codex.isAIAgent)
        XCTAssertFalse(SailorType.brew.isAIAgent)
        XCTAssertFalse(SailorType.shellCommand.isAIAgent)
        XCTAssertFalse(SailorType.unknown.isAIAgent)
    }

    func testIsShellTask() {
        XCTAssertTrue(SailorType.brew.isShellTask)
        XCTAssertTrue(SailorType.shellCommand.isShellTask)
        XCTAssertFalse(SailorType.claudeCode.isShellTask)
        XCTAssertFalse(SailorType.unknown.isShellTask)
    }

    // MARK: - Shell task display names

    func testShellDisplayNames() {
        XCTAssertEqual(SailorType.brew.displayName, "Homebrew")
        XCTAssertEqual(SailorType.btop.displayName, "btop")
        XCTAssertEqual(SailorType.shellCommand.displayName, "Shell")
    }

    // MARK: - launchCommand(withTask:)

    // Use codex here: it gets no system-prompt injection, so the exact composed
    // string is stable. Claude's injection is covered above.
    func testLaunchCommandWithTaskComposesPositionalPrompt() {
        XCTAssertEqual(
            SailorType.codex.launchCommand(withTask: "add tests"),
            "codex 'add tests'"
        )
    }

    func testLaunchCommandWithEmptyTaskReturnsBareCommand() {
        XCTAssertEqual(SailorType.codex.launchCommand(withTask: ""), "codex")
        XCTAssertEqual(SailorType.codex.launchCommand(withTask: "   "), "codex")
    }

    func testLaunchCommandWithTaskEscapesQuotes() {
        XCTAssertEqual(
            SailorType.codex.launchCommand(withTask: "can't stop"),
            "codex 'can'\\''t stop'"
        )
    }

    func testLaunchCommandWithTaskNilForNonAISailor() {
        XCTAssertNil(SailorType.npm.launchCommand(withTask: "anything"))
        XCTAssertNil(SailorType.shellCommand.launchCommand(withTask: "anything"))
    }
}
