import XCTest
@testable import seahelm

final class UnseenCompletionTests: XCTestCase {
    private func item(_ path: String, status: AgentStatus = .idle, unseen: Bool = false,
                      activity: TimeInterval = 0) -> WorktreeGroupingItem {
        WorktreeGroupingItem(id: path, path: path, repository: "alpha", status: status,
                             lastActivityAt: Date(timeIntervalSince1970: activity),
                             isMainWorktree: false, creationDate: .distantPast,
                             hasUnseenCompletion: unseen)
    }

    // MARK: - when it is set and cleared

    func testOnlyATurnEndingMarksIt() {
        XCTAssertTrue(UnseenCompletion.marks(oldStatus: .running, newStatus: .idle))
        XCTAssertFalse(UnseenCompletion.marks(oldStatus: .waiting, newStatus: .idle),
                       "answering a question is not a finished turn")
        XCTAssertFalse(UnseenCompletion.marks(oldStatus: .running, newStatus: .waiting))
    }

    func testAnythingTheAgentDoesNextClearsIt() {
        for status in [AgentStatus.running, .waiting, .error, .exited] {
            XCTAssertTrue(UnseenCompletion.clears(newStatus: status), "\(status)")
        }
        XCTAssertFalse(UnseenCompletion.clears(newStatus: .idle))
        XCTAssertFalse(UnseenCompletion.clears(newStatus: .unknown),
                       "a pane the scan lost sight of has not been read")
    }

    // MARK: - group by status

    func testFinishedSitsBetweenNeedsInputAndRunning() {
        let groups = WorktreeGrouping.groups([
            item("/a", status: .running),
            item("/b", unseen: true),
            item("/c", status: .waiting),
            item("/d"),
        ], mode: .status, now: Date())
        XCTAssertEqual(groups.map(\.id), [.status(.waiting), .unseen, .status(.running), .status(.idle)])
        XCTAssertEqual(groups[1].items.map(\.path), ["/b"])
        XCTAssertEqual(groups[1].title, UnseenCompletion.groupTitle)
    }

    func testFinishedLeadsWhenNothingNeedsInput() {
        let groups = WorktreeGrouping.groups([item("/a", status: .running), item("/b", unseen: true)],
                                             mode: .status, now: Date())
        XCTAssertEqual(groups.first?.id, .unseen)
    }

    /// The flag only means "unread" at rest; a row that is running again is
    /// running, whatever a pane beside it left unread.
    func testABusyRowIsFiledByItsStatus() {
        let groups = WorktreeGrouping.groups([item("/a", status: .running, unseen: true)],
                                             mode: .status, now: Date())
        XCTAssertEqual(groups.map(\.id), [.status(.running)])
    }

    func testWireCarriesTheFlag() {
        let groups = WorktreeGrouping.groups([item("/b", unseen: true)], mode: .status, now: Date())
        XCTAssertEqual(groups[0].dict["unseen"] as? Bool, true)
        XCTAssertEqual(groups[0].dict["id"] as? String, "status:unseen")
        XCTAssertEqual((groups[0].dict["items"] as? [[String: Any]])?.first?["unseen"] as? Bool, true)
        let plain = WorktreeGrouping.groups([item("/d")], mode: .status, now: Date())
        XCTAssertNil(plain[0].dict["unseen"])
    }

    // MARK: - the registry and the wire

    func testRegistryReportsOnlyChanges() {
        let station = Station()
        AgentRegistry.shared.register(station: station, worktreePath: "/tmp/unseen-wt",
                                      branch: "main", project: "P", startedAt: nil)
        defer { AgentRegistry.shared.unregister(terminalID: station.id) }

        XCTAssertTrue(AgentRegistry.shared.setUnseenCompletion(true, terminalID: station.id))
        XCTAssertFalse(AgentRegistry.shared.setUnseenCompletion(true, terminalID: station.id))
        XCTAssertEqual(AgentRegistry.shared.pane(for: station.id)?.unseenCompletion, true)
        XCTAssertTrue(AgentRegistry.shared.setUnseenCompletion(false, terminalID: station.id))
        XCTAssertFalse(AgentRegistry.shared.setUnseenCompletion(true, terminalID: "nobody"))
    }

    func testAMovedPaneKeepsItsUnreadFinish() {
        var info = PaneInfo(id: "t", worktreePath: "/a", agentType: .claudeCode, project: "P",
                            branch: "b", status: .idle, lastMessage: "", commandLine: nil,
                            roundDuration: 0, startedAt: nil, station: nil, channel: nil,
                            taskProgress: TaskProgress())
        info.unseenCompletion = true
        XCTAssertTrue(info.rehomed(to: "/b", branch: "b", project: "P").unseenCompletion)
    }

    func testGatewayPassesTheFlagOnAsAStatusUpdate() {
        var sent: [String: String] = [:]
        let note = HostGatewaySession.paneNotify(
            for: ["type": "pane.unseen_changed", "pane_id": "p1", "pane_session_key": "k1",
                  "worktree_path": "/a", "unseen": false],
            sentAgentTypes: &sent)
        XCTAssertEqual(note?.method, "pane.status")
        XCTAssertEqual(note?.params["unseen"] as? Bool, false)
        XCTAssertEqual(note?.params["pane_session_key"] as? String, "k1")
    }
}
