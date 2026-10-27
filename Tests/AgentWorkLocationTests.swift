import XCTest
@testable import seahelm

final class AgentWorkLocationTests: XCTestCase {
    private func bash(_ command: String) -> AgentWorkLocation.Signal? {
        AgentWorkLocation.signal(event: .toolUseStart,
                                 data: ["tool_name": "Bash", "tool_input": ["command": command]],
                                 cwd: "/r/repo")
    }

    func testLeadingCdForms() {
        XCTAssertEqual(bash("cd /r/repo-feature && git status"), .directory("/r/repo-feature"))
        XCTAssertEqual(bash("  cd /r/repo-feature; ls"), .directory("/r/repo-feature"))
        XCTAssertEqual(bash("cd \"/r/with space\" && ls"), .directory("/r/with space"))
        XCTAssertEqual(bash("cd '/r/q' && ls"), .directory("/r/q"))
        XCTAssertEqual(bash("cd ../repo-feature && ls"), .directory("/r/repo-feature"))
        XCTAssertEqual(bash("cd /r/repo-feature"), .directory("/r/repo-feature"))
        XCTAssertEqual(bash("cd ~/x && ls"), .directory(NSHomeDirectory() + "/x"))
    }

    func testCommandsWithoutAPlainLeadingCdRunInTheCwd() {
        XCTAssertEqual(bash("git status"), .cwd)
        XCTAssertEqual(bash("echo hi && cd /r/repo-feature"), .cwd)
        XCTAssertEqual(bash("cd $(git rev-parse --show-toplevel) && ls"), .cwd)
        XCTAssertEqual(bash("cd - && ls"), .cwd)
        XCTAssertEqual(bash("cd /r/a | cat"), .cwd)
    }

    func testFileWritesNameTheirDirectoryAndReadsNameNothing() {
        let edit = AgentWorkLocation.signal(event: .toolUseStart,
                                            data: ["tool_name": "Edit", "tool_input": ["file_path": "/r/wt/src/a.swift"]],
                                            cwd: "/r/repo")
        XCTAssertEqual(edit, .directory("/r/wt/src"))
        let read = AgentWorkLocation.signal(event: .toolUseStart,
                                            data: ["tool_name": "Read", "tool_input": ["file_path": "/r/wt/src/a.swift"]],
                                            cwd: "/r/repo")
        XCTAssertNil(read)
    }

    func testOnlyToolStartsCount() {
        XCTAssertNil(AgentWorkLocation.signal(event: .toolUseEnd,
                                              data: ["tool_name": "Bash", "tool_input": ["command": "cd /r/wt"]],
                                              cwd: "/r/repo"))
    }

    private func created(_ command: String) -> String? {
        AgentWorkLocation.createdWorktree(event: .toolUseStart,
                                          data: ["tool_name": "Bash", "tool_input": ["command": command]],
                                          cwd: "/r/repo")
    }

    func testGitWorktreeAddNamesTheWorktreeItCreates() {
        XCTAssertEqual(created("git worktree add ../repo-x"), "/r/repo-x")
        XCTAssertEqual(created("git fetch -q origin main && git worktree add -q -b chore/x ../repo-x origin/main"),
                       "/r/repo-x")
        XCTAssertEqual(created("git worktree add --detach -B b \"/w/with space\" HEAD"), "/w/with space")
        XCTAssertEqual(created("cd /r/other && git worktree add wt"), "/r/other/wt")
        XCTAssertEqual(created("git -C /r/other worktree add ../wt"), "/r/wt")
    }

    func testOtherCommandsCreateNothing() {
        XCTAssertNil(created("git worktree list"))
        XCTAssertNil(created("git worktree remove ../repo-x"))
        XCTAssertNil(created("echo git worktree add ../x"))
        XCTAssertNil(created("git worktree add"))
    }

    func testEnterWorktreeCreatesUnderClaudeWorktrees() {
        let path = AgentWorkLocation.createdWorktree(event: .toolUseStart,
                                                     data: ["tool_name": "EnterWorktree", "tool_input": ["name": "fix"]],
                                                     cwd: "/r/repo")
        XCTAssertEqual(path, "/r/repo/.claude/worktrees/fix")
    }
}
