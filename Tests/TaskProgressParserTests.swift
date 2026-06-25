import XCTest
@testable import seahelm

final class TaskProgressParserTests: XCTestCase {

    // MARK: - Emoji Format

    func testEmojiFormat_MixedStatuses() {
        let content = """
        Some terminal output here
        ✅ Create database schema
        🔧 Implement API endpoints
        ⬜ Write tests
        ⬜ Update documentation
        More terminal output
        """
        let result = TaskProgressParser.parse(content: content, agentType: .claudeCode)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.totalTasks, 4)
        XCTAssertEqual(result?.completedTasks, 1)
        XCTAssertEqual(result?.currentTask, "Implement API endpoints")
    }

    func testEmojiFormat_AllCompleted() {
        let content = """
        ✅ Task one
        ✅ Task two
        ✅ Task three
        """
        let result = TaskProgressParser.parse(content: content, agentType: .claudeCode)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.totalTasks, 3)
        XCTAssertEqual(result?.completedTasks, 3)
        XCTAssertNil(result?.currentTask)
    }

    func testEmojiFormat_AlternateEmoji() {
        let content = """
        ☑ Done task
        🔨 Working on this
        ☐ Not started
        """
        let result = TaskProgressParser.parse(content: content, agentType: .claudeCode)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.totalTasks, 3)
        XCTAssertEqual(result?.completedTasks, 1)
        XCTAssertEqual(result?.currentTask, "Working on this")
    }

    // MARK: - Bracket Format

    func testBracketFormat_Standard() {
        let content = """
        1. [completed] Create database schema
        2. [in_progress] Implement API endpoints
        3. [pending] Write tests
        4. [pending] Update documentation
        """
        let result = TaskProgressParser.parse(content: content, agentType: .claudeCode)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.totalTasks, 4)
        XCTAssertEqual(result?.completedTasks, 1)
        XCTAssertEqual(result?.currentTask, "Implement API endpoints")
    }

    func testBracketFormat_ShortForm() {
        let content = """
        [x] First task
        [~] Second task
        [ ] Third task
        """
        let result = TaskProgressParser.parse(content: content, agentType: .codex)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.totalTasks, 3)
        XCTAssertEqual(result?.completedTasks, 1)
        XCTAssertEqual(result?.currentTask, "Second task")
    }

    func testBracketFormat_DoneAndTodo() {
        let content = """
        [done] Setup project
        [current] Add features
        [todo] Deploy
        """
        let result = TaskProgressParser.parse(content: content, agentType: .openCode)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.totalTasks, 3)
        XCTAssertEqual(result?.completedTasks, 1)
        XCTAssertEqual(result?.currentTask, "Add features")
    }

    // MARK: - Edge Cases

    func testReturnsNilForEmptyContent() {
        let result = TaskProgressParser.parse(content: "", agentType: .claudeCode)
        XCTAssertNil(result)
    }

    func testReturnsNilForNoTaskLines() {
        let content = """
        $ npm install
        added 150 packages in 3s
        $ npm run build
        Build succeeded
        """
        let result = TaskProgressParser.parse(content: content, agentType: .claudeCode)
        XCTAssertNil(result)
    }

    func testReturnsNilForSingleTaskLine() {
        // Minimum 2 task lines to avoid false positives
        let content = "✅ Only one task here"
        let result = TaskProgressParser.parse(content: content, agentType: .claudeCode)
        XCTAssertNil(result)
    }

    func testMixedNormalTextIgnored() {
        let content = """
        Building project...
        ✅ Compile sources
        Output: 42 files processed
        🔧 Run tests
        Some error output here
        ⬜ Deploy
        Done!
        """
        let result = TaskProgressParser.parse(content: content, agentType: .claudeCode)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.totalTasks, 3)
        XCTAssertEqual(result?.completedTasks, 1)
        XCTAssertEqual(result?.currentTask, "Run tests")
    }

    func testMultipleInProgress_FirstOneWins() {
        let content = """
        ✅ Done task
        🔧 First active task
        🔧 Second active task
        ⬜ Pending task
        """
        let result = TaskProgressParser.parse(content: content, agentType: .claudeCode)
        XCTAssertEqual(result?.currentTask, "First active task")
    }

    func testAllPending() {
        let content = """
        ⬜ Task one
        ⬜ Task two
        ⬜ Task three
        """
        let result = TaskProgressParser.parse(content: content, agentType: .claudeCode)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.totalTasks, 3)
        XCTAssertEqual(result?.completedTasks, 0)
        XCTAssertNil(result?.currentTask)
    }
}
