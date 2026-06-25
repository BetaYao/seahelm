import XCTest
@testable import seahelm

final class AgentTypeTests: XCTestCase {

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

    func testLaunchCommandWithTaskComposesPositionalPrompt() {
        XCTAssertEqual(
            AgentType.claudeCode.launchCommand(withTask: "fix the login bug"),
            "claude 'fix the login bug'"
        )
        XCTAssertEqual(
            AgentType.codex.launchCommand(withTask: "add tests"),
            "codex 'add tests'"
        )
    }

    func testLaunchCommandWithEmptyTaskReturnsBareCommand() {
        XCTAssertEqual(AgentType.claudeCode.launchCommand(withTask: ""), "claude")
        XCTAssertEqual(AgentType.claudeCode.launchCommand(withTask: "   "), "claude")
    }

    func testLaunchCommandWithTaskEscapesQuotes() {
        XCTAssertEqual(
            AgentType.claudeCode.launchCommand(withTask: "can't stop"),
            "claude 'can'\\''t stop'"
        )
    }

    func testLaunchCommandWithTaskNilForNonAIAgent() {
        XCTAssertNil(AgentType.npm.launchCommand(withTask: "anything"))
        XCTAssertNil(AgentType.shellCommand.launchCommand(withTask: "anything"))
    }
}
