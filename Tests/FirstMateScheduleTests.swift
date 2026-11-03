import XCTest
@testable import seahelm

final class FirstMateScheduleTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    /// 2026-11-02 is a Monday.
    private func at(_ day: Int, _ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    // MARK: - cron

    func testWeekdayMornings() {
        let cron = CronSchedule("0 9 * * 1-5")!
        XCTAssertTrue(cron.matches(at(2, 9, 0), calendar: cal), "Monday 09:00")
        XCTAssertFalse(cron.matches(at(2, 9, 1), calendar: cal))
        XCTAssertFalse(cron.matches(at(1, 9, 0), calendar: cal), "Sunday")
        XCTAssertTrue(cron.matches(at(6, 9, 0), calendar: cal), "Friday")
    }

    func testStepsListsAndSunday() {
        XCTAssertTrue(CronSchedule("*/15 * * * *")!.matches(at(3, 4, 45), calendar: cal))
        XCTAssertFalse(CronSchedule("*/15 * * * *")!.matches(at(3, 4, 50), calendar: cal))
        XCTAssertTrue(CronSchedule("0 8,18 * * *")!.matches(at(3, 18, 0), calendar: cal))
        XCTAssertTrue(CronSchedule("0 10 * * 7")!.matches(at(1, 10, 0), calendar: cal), "7 is Sunday too")
        XCTAssertTrue(CronSchedule("0 10 * * 0")!.matches(at(1, 10, 0), calendar: cal))
    }

    func testEitherDayFieldMatchesWhenBothAreSet() {
        let cron = CronSchedule("0 9 1 * 1")!   // the 1st, or any Monday
        XCTAssertTrue(cron.matches(at(2, 9, 0), calendar: cal), "a Monday that is not the 1st")
        XCTAssertTrue(cron.matches(at(1, 9, 0), calendar: cal), "the 1st, a Sunday")
        XCTAssertFalse(cron.matches(at(3, 9, 0), calendar: cal))
    }

    func testNonsenseIsRefused() {
        for bad in ["", "* * * *", "60 * * * *", "* 24 * * *", "*/0 * * * *", "5-1 * * * *", "a * * * *"] {
            XCTAssertNil(CronSchedule(bad), bad)
        }
        XCTAssertThrowsError(try AutomationConfig.parse(
            yaml: "rules:\n  - name: x\n    on: { schedule: \"99 * * * *\" }\n    brief: b"))
    }

    func testTriageShipsButIsOff() {
        let triage = AutomationConfig.builtIn.rules.first { $0.name == "triage-issues" }
        XCTAssertNotNil(triage)
        XCTAssertEqual(triage?.enabled, false)
        XCTAssertTrue(AutomationConfig.builtIn.rules(for: .schedule("0 9 * * 1-5")).isEmpty)
    }

    // MARK: - coordinator

    private func coordinator() -> AutopilotCoordinator {
        let dir = NSTemporaryDirectory() + "sched-\(UUID().uuidString)"
        return AutopilotCoordinator(auditPath: dir + "/audit.jsonl", ledgerPath: dir + "/state.json")
    }

    func testAScheduleFiresOncePerMinuteForEachProject() throws {
        let repo = NSTemporaryDirectory() + "repo-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try AutomationConfig(rules: [
            AutomationRule(name: "hourly", trigger: .schedule("0 * * * *"), brief: "check {{repo}}"),
        ]).write(repoPath: repo)
        let c = coordinator()
        c.activateForTesting()
        c.repoPaths = { [repo] }
        let hour = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        c.checkSchedules(now: hour)
        c.checkSchedules(now: hour.addingTimeInterval(20))
        c.checkSchedules(now: hour.addingTimeInterval(120))
        let events = c.audit.recent().filter { $0.kind == .event }
        XCTAssertEqual(events.map(\.rule), ["hourly"])
        XCTAssertEqual(c.state.queued, 1)
    }

    // MARK: - proposals

    func testAProposalOffersActionsAndOnlyActions() {
        let c = coordinator()
        c.activateForTesting()
        var raised: [(String, [String])] = []
        c.onRequestProposal = { id, _, labels in raised.append((id, labels)) }
        let ok = c.propose(summary: "Worth starting", options: [
            ["label": "Start #88", "action": "worktree.create", "params": ["repo_path": "/r", "prompt": "fix 88"]],
        ])
        guard case .ok(let r) = ok else { return XCTFail("\(ok)") }
        XCTAssertEqual(r["queued"] as? String, "proposal")
        XCTAssertEqual(raised.first?.1, ["Start #88", AutopilotCoordinator.dismissLabel])
        XCTAssertEqual(c.state.pendingApprovals, 1)

        guard case .error = c.propose(summary: "s", options: [["label": "Close", "action": "pane.close"]]) else {
            return XCTFail("a forbidden method was offered")
        }
        guard case .error = c.propose(summary: "s", options: [["action": "worktree.create"]]) else {
            return XCTFail("an option without a label")
        }
    }

    func testPickingRunsThatOptionAndDismissingRunsNothing() {
        let c = coordinator()
        c.activateForTesting()
        var ran: [(String, [String: Any])] = []
        let done = expectation(description: "ran")
        c.execute = { method, params in ran.append((method, params)); done.fulfill(); return .ok(["worktree_path": "/wt/88"]) }
        var ids: [String] = []
        c.onRequestProposal = { id, _, _ in ids.append(id) }
        _ = c.propose(summary: "s", options: [
            ["label": "Start #88", "action": "worktree.create", "params": ["repo_path": "/r", "prompt": "88"]],
            ["label": "Start #91", "action": "worktree.create", "params": ["repo_path": "/r", "prompt": "91"]],
        ])
        c.resolveProposal(ids[0], picked: "Start #91")
        wait(for: [done], timeout: 2)
        XCTAssertEqual(ran.first?.1["prompt"] as? String, "91")
        XCTAssertEqual(c.state.pendingApprovals, 0)

        _ = c.propose(summary: "t", options: [["label": "A", "action": "worktree.delete",
                                                 "params": ["worktree_path": "/wt/x"]]])
        c.resolveProposal(ids[1], picked: AutopilotCoordinator.dismissLabel)
        XCTAssertEqual(ran.count, 1)
        XCTAssertEqual(c.audit.recent().last?.text, "not now: t")
    }

    func testOnlyFirstMateMayPropose() {
        final class DS: ControlDataSource {
            func snapshotPanes() -> [PaneSnapshot] { [] }
            func readPane(paneId: String, source: String, lines: Int) -> String? { nil }
            func ingestHook(json: [String: Any]) {}
            func autopilotPropose(summary: String, options: [[String: Any]]) -> ControlResult { .ok(["queued": "proposal"]) }
        }
        let router = ControlRouter(dataSource: DS())
        let params: [String: Any] = ["summary": "s", "options": [["label": "a", "action": "worktree.create"]]]
        guard case .error = router.handle(method: "autopilot.propose", params: params.merging(["_meta": ["caller": "seahelm-x"]]) { $1 })
        else { return XCTFail("another pane proposed") }
        guard case .ok = router.handle(method: "autopilot.propose",
                                       params: params.merging(["_meta": ["caller": FirstMatePane.sessionName]]) { $1 })
        else { return XCTFail("First Mate could not propose") }
    }
}

final class FirstMateApprovalsViewTests: XCTestCase {
    func testCardsOfferTheirOptionsAndReportTheAnswer() {
        let order = PendingOrder(id: "o1", action: FirstMateAction(
            kind: .autopilotApproval, zone: .red, worktreePath: "/fm", branch: "", project: "First Mate",
            terminalID: "t", message: "First Mate asks: Delete worktree x", payload: "a1",
            options: [AutopilotCoordinator.approveLabel, AutopilotCoordinator.rejectLabel]))
        let view = FirstMateApprovalsView()
        var answers: [(String, String)] = []
        view.onAnswer = { answers.append(($0.id, $1)) }
        view.show([order])
        let buttons = view.descendants(of: NSButton.self)
        XCTAssertEqual(buttons.map(\.title), ["Approve", "Reject"])
        buttons[1].performClick(nil)
        XCTAssertEqual(answers.first?.0, "o1")
        XCTAssertEqual(answers.first?.1, "Reject")
    }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.descendants(of: type) }
    }
}
