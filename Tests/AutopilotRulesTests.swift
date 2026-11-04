import XCTest
@testable import seahelm

final class AutopilotRulesTests: XCTestCase {
    private func pr(_ n: Int, _ state: WorktreePRStatus.State = .open,
                    checks: WorktreePRStatus.Checks? = nil) -> WorktreePRStatus {
        WorktreePRStatus(number: n, url: "https://github.com/acme/app/pull/\(n)", state: state,
                         checks: checks, review: nil)
    }
    private func obs(_ p: WorktreePRStatus?, wt: String = "/wt/a", branch: String = "feat/a") -> PRObservation {
        PRObservation(worktreePath: wt, repoPath: "/repo", branch: branch, pr: p)
    }
    private func ledger() -> AutopilotLedger {
        AutopilotLedger(path: NSTemporaryDirectory() + "ledger-\(UUID().uuidString).json")
    }

    // MARK: - yml

    func testParsesTheDocumentedExample() throws {
        let config = try AutomationConfig.parse(yaml: """
        first_mate:
          budget:
            max_concurrent_agents: 4
            pause_above_usage: 80
          quiet_hours: "23:00-08:00"
        rules:
          - name: fix-ci
            on: ci.failed
            when: { branch: "!main" }
            max_attempts: 2
            autonomy: { message_pane: auto, start_agent: ask }
            brief: |
              PR #{{pr}} failed.
          - name: triage
            on: { schedule: "0 9 * * 1-5" }
            brief: look at issues
        """)
        XCTAssertEqual(config.settings.maxConcurrentAgents, 4)
        XCTAssertEqual(config.settings.pauseAboveUsage, 80)
        XCTAssertNotNil(config.settings.quietHours)
        XCTAssertEqual(config.rules.count, 2)
        XCTAssertEqual(config.rules[0].trigger, .ciFailed)
        XCTAssertEqual(config.rules[0].maxAttempts, 2)
        XCTAssertEqual(config.rules[0].autonomy[.startAgent], .ask)
        XCTAssertEqual(config.rules[1].trigger, .schedule("0 9 * * 1-5"))
        XCTAssertEqual(config.autonomy(for: .deleteWorktree, rule: config.rules[0]), .ask, "falls back to the default")
    }

    func testMistakesAreNamedNotGuessed() {
        XCTAssertThrowsError(try AutomationConfig.parse(yaml: "rules:\n  - name: x\n    on: push\n    brief: b"))
        XCTAssertThrowsError(try AutomationConfig.parse(
            yaml: "rules:\n  - name: x\n    on: ci.failed\n    autonomy: { merge: auto }\n    brief: b"))
        XCTAssertThrowsError(try AutomationConfig.parse(
            yaml: "rules:\n  - name: x\n    on: ci.failed\n    autonomy: { start_agent: yes }\n    brief: b"))
        XCTAssertThrowsError(try AutomationConfig.parse(yaml: "rules:\n  - name: x\n    on: ci.failed"))
        XCTAssertThrowsError(try AutomationConfig.parse(yaml: "- just a list"))
    }

    func testABrokenFileStopsTheRepoRatherThanFallingBack() throws {
        let repo = NSTemporaryDirectory() + "auto-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: repo) }
        XCTAssertEqual(AutomationConfig.load(repoPath: repo).config, .builtIn)
        try FileManager.default.createDirectory(atPath: repo + "/.seahelm", withIntermediateDirectories: true)
        try "rules: [ {name: x} ]".write(toFile: repo + "/.seahelm/automations.yml", atomically: true, encoding: .utf8)
        let loaded = AutomationConfig.load(repoPath: repo)
        XCTAssertNil(loaded.config)
        XCTAssertNotNil(loaded.error)
    }

    func testBranchFiltersAndQuietHours() {
        XCTAssertFalse(BranchFilter(pattern: "!main").matches("main"))
        XCTAssertTrue(BranchFilter(pattern: "!main").matches("feat/x"))
        XCTAssertTrue(BranchFilter(pattern: "feat/*").matches("feat/x"))
        XCTAssertFalse(BranchFilter(pattern: "feat/*").matches("fix/x"))

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let at = { (h: Int, m: Int) in cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: h, minute: m))! }
        let night = QuietHours("23:00-08:00")!
        XCTAssertTrue(night.contains(at(23, 30), calendar: cal))
        XCTAssertTrue(night.contains(at(7, 59), calendar: cal))
        XCTAssertFalse(night.contains(at(8, 0), calendar: cal))
        XCTAssertFalse(night.contains(at(12, 0), calendar: cal))
        XCTAssertNil(QuietHours("25:00-08:00"))
    }

    // MARK: - events

    func testCIFailedFiresOnTheEdgeOnly() {
        var d = PREventDetector()
        XCTAssertTrue(d.observe([obs(pr(1, checks: .failing))], alreadyMerged: { _ in false }).isEmpty,
                      "already red at first sight is not news")
        XCTAssertTrue(d.observe([obs(pr(1, checks: .failing))], alreadyMerged: { _ in false }).isEmpty)
        XCTAssertTrue(d.observe([obs(pr(1, checks: .pending))], alreadyMerged: { _ in false }).isEmpty)
        let events = d.observe([obs(pr(1, checks: .failing))], alreadyMerged: { _ in false })
        XCTAssertEqual(events.map(\.trigger), [.ciFailed], "a fix that failed again is news again")
    }

    func testANewPRThatFailsIsNews() {
        var d = PREventDetector()
        _ = d.observe([obs(pr(1, checks: .failing))], alreadyMerged: { _ in false })
        XCTAssertEqual(d.observe([obs(pr(2, checks: .failing))], alreadyMerged: { _ in false }).map(\.trigger),
                       [.ciFailed])
    }

    func testMergedFiresAtFirstSightButOnlyOnce() {
        var d = PREventDetector()
        let events = d.observe([obs(pr(5, .merged))], alreadyMerged: { _ in false })
        XCTAssertEqual(events.map(\.trigger), [.prMerged])
        XCTAssertTrue(d.observe([obs(pr(5, .merged))], alreadyMerged: { $0 == "/repo#5" }).isEmpty)
    }

    // MARK: - matching

    func testRulesMatchByTriggerBranchAndAttempts() {
        let l = ledger()
        let event = AutopilotEvent(trigger: .ciFailed, repoPath: "/repo", worktreePath: "/wt/a",
                                   branch: "feat/a", pr: pr(7, checks: .failing))
        let day = "2026-11-03"
        var out = AutopilotEngine.dispatches(for: event, config: .builtIn, ledger: l, day: day)
        XCTAssertEqual(out.map(\.rule.name), ["fix-ci"])
        XCTAssertTrue(out[0].prompt.contains("PR #7 on feat/a failed CI"))
        XCTAssertTrue(out[0].prompt.hasPrefix("[seahelm event] ci.failed · rule fix-ci"))
        XCTAssertTrue(out[0].prompt.contains("start_agent=ask"))

        l.recordAttempt(rule: "fix-ci", repoPath: "/repo", pr: 7, day: day)
        l.recordAttempt(rule: "fix-ci", repoPath: "/repo", pr: 7, day: day)
        out = AutopilotEngine.dispatches(for: event, config: .builtIn, ledger: l, day: day)
        XCTAssertTrue(out.isEmpty, "max_attempts reached for today")
        XCTAssertEqual(AutopilotEngine.dispatches(for: event, config: .builtIn, ledger: l, day: "2026-11-04").count, 1)

        let onMain = AutopilotEvent(trigger: .ciFailed, repoPath: "/repo", worktreePath: "/repo",
                                    branch: "main", pr: pr(8, checks: .failing))
        XCTAssertTrue(AutopilotEngine.dispatches(for: onMain, config: .builtIn, ledger: l, day: day).isEmpty)
    }

    func testUnknownPlaceholdersStayVisible() {
        let rule = AutomationRule(name: "r", trigger: .ciFailed, brief: "{{pr}} {{nope}}")
        let event = AutopilotEvent(trigger: .ciFailed, repoPath: "/r", worktreePath: "/w", branch: "b", pr: pr(3))
        XCTAssertEqual(AutopilotEngine.render(rule.brief, event: event, rule: rule), "3 {{nope}}")
    }

    func testLedgerPersists() {
        let path = NSTemporaryDirectory() + "ledger-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        AutopilotLedger(path: path).markMergeHandled("/repo#5")
        XCTAssertTrue(AutopilotLedger(path: path).hasHandledMerge("/repo#5"))
    }

    func testAuditReadsBackWhatItWrote() {
        let path = NSTemporaryDirectory() + "audit-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let audit = AutopilotAudit(path: path)
        audit.append(.init(at: Date(timeIntervalSince1970: 1), kind: .event, rule: "fix-ci", text: "a"))
        audit.append(.init(at: Date(timeIntervalSince1970: 2), kind: .action, action: "message_pane", text: "b"))
        XCTAssertEqual(audit.recent().map(\.text), ["a", "b"])
        XCTAssertEqual(audit.recent(limit: 1).map(\.text), ["b"])
    }
}

final class FirstMatePaneTests: XCTestCase {
    func testProvisionWritesTheManagedFilesAndKeepsStandingOrders() throws {
        let dir = NSTemporaryDirectory() + "fm-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FirstMatePane.provision(at: dir)
        let claude = try String(contentsOfFile: dir + "/CLAUDE.md", encoding: .utf8)
        XCTAssertTrue(claude.contains("You are First Mate"))
        let settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: dir + "/.claude/settings.json"))) as? [String: Any]
        let allow = (settings?["permissions"] as? [String: Any])?["allow"] as? [String]
        XCTAssertTrue(allow?.contains("Bash(seahelm:*)") == true)
        XCTAssertFalse(allow?.contains(where: { $0.hasPrefix("Bash(git push") }) == true,
                       "a push is not First Mate's to make unasked")

        try "keep off saas-mono".write(toFile: dir + "/standing-orders.md", atomically: true, encoding: .utf8)
        try "stale".write(toFile: dir + "/CLAUDE.md", atomically: true, encoding: .utf8)
        FirstMatePane.provision(at: dir)
        XCTAssertEqual(try String(contentsOfFile: dir + "/standing-orders.md", encoding: .utf8), "keep off saas-mono")
        XCTAssertTrue(try String(contentsOfFile: dir + "/CLAUDE.md", encoding: .utf8).contains("You are First Mate"),
                      "a stale managed file is rewritten")
    }

    func testFirstMateNeverInheritsABypass() throws {
        XCTAssertTrue(FirstMatePane.launchCommand.contains("--permission-mode default"))
        XCTAssertFalse(FirstMatePane.launchCommand.contains("dangerously"))
        let permissions = FirstMatePane.permissions["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["defaultMode"] as? String, "default")
    }

    func testAnOldSessionIsNotCurrent() {
        let dir = NSTemporaryDirectory() + "fmv-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertFalse(FirstMatePane.sessionIsCurrent(at: dir))
        try? "1".write(toFile: dir + "/.session-version", atomically: true, encoding: .utf8)
        XCTAssertFalse(FirstMatePane.sessionIsCurrent(at: dir))
        FirstMatePane.markSessionCurrent(at: dir)
        XCTAssertTrue(FirstMatePane.sessionIsCurrent(at: dir))
    }


}

final class WorktreeFactsTests: XCTestCase {
    func testStatusAndShortstatParse() {
        let status = " D pnpm-lock.yaml\n M AGENTS.md\nD  config/x.env\n?? CLAUDE.md\n"
        let s = WorktreeFacts.parseStatus(status)
        XCTAssertEqual(s.changed, 3)
        XCTAssertEqual(s.deleted, 2)
        XCTAssertEqual(s.untracked, 1)
        let stat = WorktreeFacts.parseShortstat(" 41 files changed, 16 insertions(+), 47942 deletions(-)\n")
        XCTAssertEqual(stat.insertions, 16)
        XCTAssertEqual(stat.deletions, 47942)
        XCTAssertEqual(WorktreeFacts.parseShortstat(" 1 file changed, 2 deletions(-)").insertions, 0)
    }

    /// The case that slipped past First Mate's own summary: 41 files, mostly deletions.
    func testSummarySaysWhatIsThere() {
        let f = WorktreeFacts(changedFiles: 40, deletedFiles: 40, untrackedFiles: 1, insertions: 16,
                              deletions: 47942, unpushedCommits: 0, busyPanes: 0)
        XCTAssertEqual(f.summary, "41 files uncommitted (+16 −47942; 40 deleted, 1 untracked) · every commit is on a remote · panes idle")
        XCTAssertFalse(f.isClean)
        XCTAssertEqual(WorktreeFacts(unpushedCommits: 0).summary, "nothing uncommitted · every commit is on a remote · panes idle")
        XCTAssertTrue(WorktreeFacts(unpushedCommits: 0).isClean)
    }

    func testProbeMeasuresARealWorktree() throws {
        let dir = NSTemporaryDirectory() + "facts-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func git(_ args: String...) { _ = GitProcess.run(args, in: dir) }
        git("init", "-q"); git("config", "user.email", "t@t"); git("config", "user.name", "t")
        try "a\nb\n".write(toFile: dir + "/kept.txt", atomically: true, encoding: .utf8)
        try "x\n".write(toFile: dir + "/gone.txt", atomically: true, encoding: .utf8)
        git("add", "."); git("commit", "-qm", "one")
        try FileManager.default.removeItem(atPath: dir + "/gone.txt")
        try "new\n".write(toFile: dir + "/fresh.txt", atomically: true, encoding: .utf8)
        let f = WorktreeFacts.probe(worktreePath: dir)
        XCTAssertEqual(f.changedFiles, 1)
        XCTAssertEqual(f.deletedFiles, 1)
        XCTAssertEqual(f.untrackedFiles, 1)
        XCTAssertEqual(f.deletions, 1)
        XCTAssertEqual(f.unpushedCommits, 1, "no remote at all: the one commit is on none")
    }

    func testTheEventPromptCarriesTheFacts() {
        var event = AutopilotEvent(trigger: .prMerged, repoPath: "/r", worktreePath: "/w", branch: "b",
                                   pr: WorktreePRStatus(number: 5, url: "u", state: .merged, checks: nil, review: nil))
        event.facts = WorktreeFacts(changedFiles: 2, insertions: 3, deletions: 4, unpushedCommits: 0, busyPanes: 1)
        let prompt = AutopilotEngine.prompt(rule: AutomationConfig.builtIn.rules[1], event: event, config: .builtIn)
        XCTAssertTrue(prompt.contains("facts (measured by seahelm"), prompt)
        XCTAssertTrue(prompt.contains("2 files uncommitted (+3 −4) · every commit is on a remote · 1 pane busy"), prompt)
    }

}

final class FirstMateAgentTests: XCTestCase {
    /// Neither agent may start without its bounds.
    func testEachAgentStartsHeld() {
        XCTAssertEqual(FirstMatePane.launchCommand(for: .claudeCode), "claude --permission-mode default")
        let codex = FirstMatePane.launchCommand(for: .codex)
        XCTAssertTrue(codex.contains("--sandbox workspace-write"), codex)
        XCTAssertTrue(codex.contains("--ask-for-approval on-request"), codex)
        XCTAssertTrue(codex.contains("network_access=true"), "gh and the seahelm socket need it")
        for agent in FirstMatePane.agents {
            XCTAssertFalse(FirstMatePane.launchCommand(for: agent).contains("dangerously"), "\(agent)")
        }
    }

    func testSwitchingAgentMakesTheSessionStale() {
        let dir = NSTemporaryDirectory() + "fma-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FirstMatePane.markSessionCurrent(agent: .claudeCode, at: dir)
        XCTAssertTrue(FirstMatePane.sessionIsCurrent(agent: .claudeCode, at: dir))
        XCTAssertFalse(FirstMatePane.sessionIsCurrent(agent: .codex, at: dir))
    }

    func testBothAgentsFindTheInstructions() throws {
        let dir = NSTemporaryDirectory() + "fmi-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FirstMatePane.provision(at: dir)
        for name in ["CLAUDE.md", "AGENTS.md"] {
            XCTAssertTrue(try String(contentsOfFile: dir + "/" + name, encoding: .utf8).contains("You are First Mate"), name)
        }
    }
}
