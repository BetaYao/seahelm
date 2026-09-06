import XCTest
@testable import seahelm

/// A host that records every side effect and answers from a fixed fleet.
final class FakeCommandHost: CommandHost {
    var index = CommandFixture.index
    var desktopBoundPaneKey: String?
    var integrationEnabled = true

    var sent: [(paneId: String, text: String)] = []
    var selected: [String] = []
    var created: [(task: String, repoPath: String)] = []
    var createResult: String? = "/repo/feat-x"
    var deleted: [String] = []
    var forgotten: [String] = []
    var confirmAnswer = true
    var confirmations: [String] = []
    var facts: [String: WorktreeReturnFacts] = [:]
    var assessed: [String] = []
    var performed: [(plan: WorktreeReturnPlan, path: String)] = []
    var returnOutcome: WorktreeReturnOutcome = {
        var o = WorktreeReturnOutcome()
        o.prURL = "https://github.com/acme/alpha/pull/7"
        o.deletesWorktree = true
        o.deletesBranch = true
        return o
    }()
    var integrationCheckouts: Set<String> = []
    var integrations: [(IntegrationConflictMode, Bool)] = []
    var integrateResult: (String, Bool) = ("integrated feat-x", false)
    var ideas: [String] = []
    var issues: [String] = []
    var addRepoCalls = 0

    func fleetIndex() -> FleetIndex { index }
    func createWorktree(task: String, repoPath: String, completion: @escaping (String?) -> Void) {
        created.append((task, repoPath))
        completion(createResult)
    }
    func selectWorktree(path: String) { selected.append(path) }
    func sendText(paneId: String, text: String) -> Bool {
        guard index.pane(id: paneId) != nil else { return false }
        sent.append((paneId, text))
        return true
    }
    func transcript(paneSessionKey: String) -> String? { "$ swift build\nBuild complete" }
    func activity(paneId: String) -> [String] { ["Bash — swift build"] }
    func assessReturn(worktreePath: String, completion: @escaping (WorktreeReturnFacts) -> Void) {
        assessed.append(worktreePath)
        completion(facts[worktreePath] ?? cleanMergedFacts(branch: index.worktree(path: worktreePath)?.branch ?? ""))
    }
    func performReturn(_ plan: WorktreeReturnPlan, worktree: WorktreeRef,
                       completion: @escaping (WorktreeReturnOutcome) -> Void) {
        performed.append((plan, worktree.path))
        if case .delete(let deleteBranch, _) = plan {
            deleted.append(worktree.path)
            var outcome = WorktreeReturnOutcome()
            outcome.deletesWorktree = true
            outcome.deletesBranch = deleteBranch
            completion(outcome)
        } else {
            if returnOutcome.deletesWorktree { deleted.append(worktree.path) }
            completion(returnOutcome)
        }
    }
    func isIntegrationCheckout(worktreePath: String) -> Bool { integrationCheckouts.contains(worktreePath) }

    /// A worktree with nothing to ship: what `/return` deletes without asking.
    func cleanMergedFacts(branch: String) -> WorktreeReturnFacts {
        var f = WorktreeReturnFacts(branch: branch)
        f.baseBranch = "main"
        f.fetchedBase = true
        f.baseOnRemote = true
        f.unshippedCommits = 0
        f.remote = .github(owner: "acme", repo: "alpha")
        return f
    }

    /// A worktree with work on it: what `/return` ships.
    func dirtyFacts(branch: String, files: Int = 3) -> WorktreeReturnFacts {
        var f = cleanMergedFacts(branch: branch)
        f.uncommittedFileCount = files
        f.unshippedCommits = 1
        f.hasGitHubToken = true
        f.taskDescription = "fix the flaky test"
        return f
    }
    func forgetRepo(path: String) { forgotten.append(path) }
    func integrate(mode: IntegrationConflictMode, force: Bool, completion: @escaping (String, Bool) -> Void) {
        integrations.append((mode, force))
        completion(integrateResult.0, integrateResult.1)
    }
    func addIdea(text: String, source: String) -> String { ideas.append("\(source): \(text)"); return text }
    func openIssue(title: String) { issues.append(title) }
    func addRepo() { addRepoCalls += 1 }
    func confirm(_ summary: String, completion: @escaping (Bool) -> Void) {
        confirmations.append(summary)
        completion(confirmAnswer)
    }
}

final class CommandExecutorTests: XCTestCase {
    private var host: FakeCommandHost!
    private var sessions: CommandSessionStore!
    private var executor: CommandExecutor!
    private let phone = CommandSurface(sessionKey: "telegram:42", commander: "42")

    override func setUp() {
        super.setUp()
        host = FakeCommandHost()
        sessions = CommandSessionStore(url: nil, legacyMailURL: nil)
        executor = CommandExecutor(host: host, sessions: sessions)
    }

    @discardableResult
    private func run(_ text: String, on surface: CommandSurface? = nil) -> [CommandReply] {
        var replies: [CommandReply] = []
        executor.run(text, surface: surface ?? phone) { replies.append($0) }
        return replies
    }

    private func last(_ text: String, on surface: CommandSurface? = nil) -> CommandReply {
        run(text, on: surface).last ?? .error("no reply")
    }

    // MARK: - Binding

    func testProseWithNothingBoundExplainsHowToBind() {
        let reply = last("hello")
        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.text.contains("/go"), reply.text)
        XCTAssertTrue(host.sent.isEmpty)
    }

    /// One pane is no choice at all.
    func testProseAutoBindsWhenOnlyOnePaneExists() {
        host.index = FleetIndex(panes: [CommandFixture.paneC], worktrees: [], repos: [])
        let reply = last("hello")
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertEqual(host.sent.map(\.text), ["hello"])
        XCTAssertEqual(sessions.session(for: "telegram:42").boundPaneKey, "k12")
        XCTAssertTrue(reply.text.contains("from now on"), reply.text)
    }

    func testGoBindsThisConversationOnly() {
        let reply = last("/go #7")
        XCTAssertTrue(reply.text.contains("#7 alpha/feat-x"), reply.text)
        XCTAssertEqual(sessions.session(for: "telegram:42").boundPaneKey, "k7")
        XCTAssertEqual(sessions.session(for: "telegram:42").commander, "42")
        XCTAssertTrue(host.selected.isEmpty, "a phone's /go must not move the desktop")

        last("run the tests")
        XCTAssertEqual(host.sent.map { "\($0.paneId):\($0.text)" }, ["b:run the tests"])
        XCTAssertEqual(last("more").text, "→ #7 alpha/feat-x")
    }

    func testGoOnTheDesktopSelectsInstead() {
        last("/go #12", on: .desktop)
        XCTAssertEqual(host.selected, ["/beta/main"])
        XCTAssertNil(sessions.session(for: "desktop").boundPaneKey)
    }

    func testDesktopProseGoesToTheSelectedPane() {
        host.desktopBoundPaneKey = "k3"
        XCTAssertEqual(last("hi", on: .desktop).text, "→ #3 alpha/feat-x")
        XCTAssertEqual(host.sent.map(\.paneId), ["a"])
    }

    func testGoWorktreeBindsItsFirstPane() {
        last("/go @feat-x")
        XCTAssertEqual(sessions.session(for: "telegram:42").boundPaneKey, "k3", "lowest handle in the worktree")
    }

    func testGoEmptyWorktreeBindsThePlaceUntilAPaneAppears() {
        let reply = last("/go @fix-y")
        XCTAssertTrue(reply.text.contains("no pane there yet"), reply.text)
        XCTAssertTrue(last("hi").isError)

        let newcomer = PaneRef(handle: 20, handleKey: "k20", id: "n", project: "beta", branch: "fix-y",
                               worktreePath: "/repo/fix-y", type: "Claude", title: "new")
        host.index.panes.append(newcomer)
        XCTAssertEqual(last("hi").text, "→ #20 beta/fix-y")
        XCTAssertEqual(sessions.session(for: "telegram:42").boundPaneKey, "k20", "the binding upgrades to the pane")
    }

    func testClosedPaneUnbinds() {
        last("/go #7")
        sessions.close(paneId: "b")
        XCTAssertTrue(last("hi").isError)
    }

    // MARK: - Reads and one-off sends

    func testShowDoesNotBind() {
        let reply = last("/show #3")
        XCTAssertTrue(reply.text.contains("Build complete"), reply.text)
        XCTAssertTrue(reply.text.contains("#3 alpha/feat-x"), reply.text)
        XCTAssertNil(sessions.session(for: "telegram:42").boundPaneKey)
    }

    func testShowWithoutArgumentReadsTheBoundPane() {
        XCTAssertTrue(last("/show").isError)
        last("/go #12")
        XCTAssertTrue(last("/show").text.contains("#12 beta/main"))
    }

    func testOrderLeavesTheBindingAlone() {
        last("/go #7")
        XCTAssertEqual(last("/order #3 run tests").text, "→ #3 alpha/feat-x")
        XCTAssertEqual(host.sent.last?.paneId, "a")
        XCTAssertEqual(sessions.session(for: "telegram:42").boundPaneKey, "k7")
    }

    func testStatusNavigatesOnTheDesktopAndListsInChat() {
        XCTAssertTrue(last("/status", on: .desktop).showsOverview)
        let chat = last("/status")
        XCTAssertFalse(chat.showsOverview)
        XCTAssertTrue(chat.text.contains("#7"), chat.text)
    }

    // MARK: - Confirmation

    func testBroadcastAsksThenYesSends() {
        let ask = last("/broadcast hi all")
        XCTAssertTrue(ask.text.contains("/yes"), ask.text)
        XCTAssertTrue(ask.text.contains("#3 #7 #12"), ask.text)
        XCTAssertTrue(host.sent.isEmpty)

        XCTAssertEqual(last("/yes").text, "Sent to 3 panes.")
        XCTAssertEqual(host.sent.count, 3)
        XCTAssertTrue(last("/yes").isError, "a question is answered once")
    }

    func testAnyOtherLineWithdrawsTheQuestion() {
        last("/broadcast hi")
        last("/status")
        XCTAssertEqual(last("/yes").text, "Nothing to confirm.")
        XCTAssertTrue(host.sent.isEmpty)
    }

    func testForceSkipsTheQuestion() {
        XCTAssertEqual(last("/broadcast hi force").text, "Sent to 3 panes.")
    }

    func testExpiredQuestionIsGone() {
        sessions.setPending(PendingAction(line: ParsedLine(.broadcast("x"), force: true), summary: "x",
                                          expiresAt: Date().addingTimeInterval(-1)), for: "telegram:42")
        XCTAssertTrue(last("/yes").isError)
    }

    func testDesktopAsksWithASheet() {
        last("/broadcast hi", on: .desktop)
        XCTAssertEqual(host.confirmations.count, 1)
        XCTAssertEqual(host.sent.count, 3)

        host.confirmAnswer = false
        last("/broadcast again", on: .desktop)
        XCTAssertEqual(host.sent.count, 3, "a cancelled sheet sends nothing")
    }

    // MARK: - Worktrees and repos

    func testReturnRefusesARunningWorktree() {
        var f = host.cleanMergedFacts(branch: "feat-x")
        f.agentRunning = true
        host.facts["/repo/feat-x"] = f
        XCTAssertTrue(last("/return @feat-x").text.contains("agent running"))
        XCTAssertTrue(host.performed.isEmpty)
    }

    /// Nothing would be lost, so nothing is asked — the row's Delete rule.
    func testReturnDeletesAMergedWorktreeWithoutAsking() {
        let reply = last("/return @feat-x")
        XCTAssertTrue(host.confirmations.isEmpty)
        XCTAssertEqual(host.deleted, ["/repo/feat-x"])
        XCTAssertTrue(reply.text.contains("Returned @feat-x"), reply.text)
        XCTAssertTrue(reply.text.contains("Branch deleted"), reply.text)
    }

    func testReturnWithWorkAsksWithThePlanThenShips() {
        host.facts["/repo/feat-x"] = host.dirtyFacts(branch: "feat-x")
        let ask = last("/return @feat-x")
        XCTAssertTrue(ask.text.contains("commit 3 files"), ask.text)
        XCTAssertTrue(ask.text.contains("push feat-x"), ask.text)
        XCTAssertTrue(ask.text.contains("open a PR against main"), ask.text)
        XCTAssertTrue(ask.text.contains("delete the worktree and its branch"), ask.text)
        XCTAssertTrue(host.performed.isEmpty)
        let done = last("/yes")
        XCTAssertEqual(host.performed.count, 1)
        XCTAssertTrue(done.text.contains("pull/7"), done.text)
        XCTAssertTrue(done.text.contains("Returned @feat-x"), done.text)
        XCTAssertTrue(done.presentsOnDesktop)
    }

    func testReturnFailureLeavesTheWorktree() {
        host.facts["/repo/feat-x"] = host.dirtyFacts(branch: "feat-x")
        var failed = WorktreeReturnOutcome()
        failed.failure = "Push failed: rejected"
        host.returnOutcome = failed
        _ = last("/return @feat-x")
        let done = last("/yes")
        XCTAssertTrue(done.isError)
        XCTAssertTrue(done.text.contains("stays"), done.text)
        XCTAssertTrue(host.deleted.isEmpty)
    }

    func testReturnWithForceSkipsTheQuestion() {
        host.facts["/repo/feat-x"] = host.dirtyFacts(branch: "feat-x")
        let done = last("/return @feat-x force")
        XCTAssertTrue(host.confirmations.isEmpty)
        XCTAssertEqual(host.performed.count, 1)
        XCTAssertTrue(done.text.contains("Returned @feat-x"), done.text)
    }

    /// A sweep deletes only what has nothing to ship; the rest is listed with
    /// its plan and the command that runs it, never opened as PRs en masse.
    func testBareReturnDeletesTheMergedAndListsTheRest() {
        host.facts["/repo/fix-y"] = host.dirtyFacts(branch: "fix-y")
        let reply = last("/return")
        XCTAssertEqual(host.deleted, ["/repo/feat-x"])
        XCTAssertTrue(reply.text.contains("Returned 1 worktree: @feat-x"), reply.text)
        XCTAssertTrue(reply.text.contains("@fix-y"), reply.text)
        XCTAssertTrue(reply.text.contains("`/return @fix-y`"), reply.text)
        XCTAssertTrue(host.confirmations.isEmpty)
    }

    func testBareReturnSkipsTheIntegrationCheckout() {
        host.integrationCheckouts = ["/repo/fix-y"]
        _ = last("/return")
        XCTAssertEqual(host.assessed, ["/repo/feat-x"])
    }

    func testForgetAsksThenDrops() {
        let ask = last("/forget @alpha")
        XCTAssertTrue(ask.text.contains("stay on disk"), ask.text)
        last("/yes")
        XCTAssertEqual(host.forgotten, ["/workspaces/alpha"])
    }

    // MARK: - /new

    func testNewCreatesSelectsOnDesktopAndBindsInChat() {
        let replies = run("/new build login")
        XCTAssertEqual(host.created.map(\.task), ["build login"])
        XCTAssertEqual(host.created.map(\.repoPath), ["/workspaces/alpha"], "first repo by default")
        XCTAssertEqual(replies.count, 2)
        XCTAssertTrue(replies[1].text.contains("#3 alpha/feat-x"), replies[1].text)
        XCTAssertEqual(sessions.session(for: "telegram:42").boundPaneKey, "k3")
        XCTAssertTrue(host.selected.isEmpty)

        run("/new @beta more", on: .desktop)
        XCTAssertEqual(host.created.last?.repoPath, "/workspaces/beta")
        XCTAssertEqual(host.selected, ["/repo/feat-x"])
    }

    func testNewWithoutAPaneYetBindsTheWorktree() {
        host.createResult = "/repo/fix-y"
        let replies = run("/new fix it")
        XCTAssertTrue(replies.last?.text.contains("as soon as its agent is up") == true, replies.last?.text ?? "")
        XCTAssertEqual(sessions.session(for: "telegram:42").boundWorktreePath, "/repo/fix-y")
    }

    func testNewFailureIsReported() {
        host.createResult = nil
        XCTAssertTrue(run("/new x").last?.isError == true)
    }

    // MARK: - Integrate

    func testIntegrateHeldByLocalEditsAsksBeforeForcing() {
        host.integrateResult = ("not checked out — local edits", true)
        let ask = last("/integrate")
        XCTAssertTrue(ask.text.contains("/yes"), ask.text)
        XCTAssertEqual(host.integrations.map(\.1), [false])
        last("/yes")
        XCTAssertEqual(host.integrations.map(\.1), [false, true])
    }

    func testIntegrateOffIsAnError() {
        host.integrationEnabled = false
        XCTAssertTrue(last("/integrate").isError)
    }

    // MARK: - The rest

    func testIdeaFeedbackHelpAdd() {
        XCTAssertEqual(last("/idea dark mode").text, "Idea added: dark mode")
        XCTAssertEqual(host.ideas, ["telegram:42: dark mode"])
        last("/feedback it broke")
        XCTAssertEqual(host.issues, ["it broke"])
        XCTAssertTrue(last("/help").text.contains("/new"))
        XCTAssertTrue(last("/help go").text.contains("/go"))
        XCTAssertTrue(last("/add").isError)
        last("/add", on: .desktop)
        XCTAssertEqual(host.addRepoCalls, 1)
    }

    func testErrorsAreReportedAsErrors() {
        XCTAssertTrue(last("/go #99").isError)
        XCTAssertTrue(last("/nope").text.contains("/help"))
    }
}
