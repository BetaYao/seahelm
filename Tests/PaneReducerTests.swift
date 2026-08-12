import XCTest
@testable import seahelm

final class PaneReducerTests: XCTestCase {
    private func makeInfo(status: AgentStatus = .unknown, message: String = "") -> PaneInfo {
        PaneInfo(id: "t1", worktreePath: "/wt", agentType: .unknown,
                   project: "proj", branch: "main", status: status, lastMessage: message,
                   commandLine: nil, roundDuration: 0, startedAt: nil, station: nil,
                   channel: nil, taskProgress: TaskProgress())
    }

    func testApplyDetectsStatusChange() {
        let info = makeInfo(status: .idle, message: "old")
        let out = PaneReducer.apply(to: info, status: .running, lastMessage: "new",
                                      roundDuration: 5, tasks: [], lastUserPrompt: "")
        XCTAssertTrue(out.changed)
        XCTAssertEqual(out.previousStatus, .idle)
        XCTAssertEqual(out.info.status, .running)
        XCTAssertEqual(out.info.lastMessage, "new")
        XCTAssertEqual(out.info.roundDuration, 5)
    }

    func testApplyNoChangeWhenIdentical() {
        let info = makeInfo(status: .running, message: "same")
        let out = PaneReducer.apply(to: info, status: .running, lastMessage: "same",
                                      roundDuration: 0, tasks: [], lastUserPrompt: "")
        XCTAssertFalse(out.changed)
    }

    func testApplyKeepsExistingUserPromptWhenBlank() {
        var info = makeInfo()
        info.lastUserPrompt = "keep me"
        let out = PaneReducer.apply(to: info, status: .running, lastMessage: "m",
                                      roundDuration: 0, tasks: [], lastUserPrompt: "")
        XCTAssertEqual(out.info.lastUserPrompt, "keep me")
    }
}
