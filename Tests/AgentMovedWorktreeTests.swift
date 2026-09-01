// tests/AgentMovedWorktreeTests.swift
//
// The signal end of "an agent moved into a worktree of its own": a hook event's
// cwd is the only thing that reports it, and every hook payload carries one.
//
// This layer is where the shipped bug lived, and why it survived: the tracker had
// tests, the transfer had tests, and nothing tested whether a real event could
// ever reach them. These drive WebhookStatusProvider with events shaped like the
// ones Claude Code actually sends.
import XCTest
@testable import seahelm

final class AgentMovedWorktreeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seahelm-moved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Same normalization the provider applies to both sides before comparing.
    private func canon(_ url: URL) -> String {
        (url.path as NSString).resolvingSymlinksInPath
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A linked worktree root: a directory holding a `.git` *file*.
    private func makeWorktreeRoot(_ url: URL) throws {
        try makeDirectory(url)
        FileManager.default.createFile(atPath: url.appendingPathComponent(".git").path,
                                       contents: Data("gitdir: /elsewhere\n".utf8))
    }

    private func event(cwd: String, paneId: String? = "seahelm-repo-main") -> WebhookEvent {
        WebhookEvent(source: "claude-code", sessionId: "s1", event: .toolUseEnd,
                     cwd: cwd, timestamp: nil, data: ["tool_name": "Bash"], paneId: paneId)
    }

    // MARK: -

    /// Claude Code's own `EnterWorktree` puts the new worktree at
    /// `<repo>/.claude/worktrees/<name>` — *inside* the worktree it was created
    /// from. The provider's prefix match therefore resolved every event from it
    /// to the parent, so the agent's move was invisible no matter which hook
    /// fired and the pane never followed it.
    func testWorktreeNestedInsideAKnownOneIsDetected() throws {
        let repo = root.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent(".claude/worktrees/feature")
        try makeDirectory(repo)
        try makeWorktreeRoot(nested)

        let provider = WebhookStatusProvider()
        provider.updateWorktrees([repo.path])

        let detected = expectation(description: "untracked worktree reported")
        var reportedPath: String?
        var reportedPane: String?
        provider.onNewWorktreeDetected = { path, paneId in
            reportedPath = path
            reportedPane = paneId
            detected.fulfill()
        }

        provider.handleEvent(event(cwd: nested.path))

        wait(for: [detected], timeout: 2)
        XCTAssertEqual(reportedPath, canon(nested))
        XCTAssertEqual(reportedPane, "seahelm-repo-main",
                       "without the pane id we cannot move that pane rather than its siblings")
    }

    /// The same check must not fire for an agent that merely cd'd into a
    /// subdirectory, which is ordinary and constant.
    func testPlainSubdirectoryIsNotTreatedAsAWorktree() throws {
        let repo = root.appendingPathComponent("repo")
        let subdir = repo.appendingPathComponent("Sources/Core")
        try makeDirectory(repo)
        try makeDirectory(subdir)

        let provider = WebhookStatusProvider()
        provider.updateWorktrees([repo.path])

        let notDetected = expectation(description: "no discovery request")
        notDetected.isInverted = true
        provider.onNewWorktreeDetected = { _, _ in notDetected.fulfill() }

        provider.handleEvent(event(cwd: subdir.path))

        wait(for: [notDetected], timeout: 0.6)
    }

    /// A cwd under no known worktree at all still asks for discovery — that path
    /// is how a brand new sibling worktree gets picked up.
    func testCompletelyUnknownPathIsStillReported() throws {
        let repo = root.appendingPathComponent("repo")
        let sibling = root.appendingPathComponent("repo-worktrees/feature")
        try makeDirectory(repo)
        try makeDirectory(sibling)

        let provider = WebhookStatusProvider()
        provider.updateWorktrees([repo.path])

        let detected = expectation(description: "unknown path reported")
        var reportedPath: String?
        provider.onNewWorktreeDetected = { path, _ in
            reportedPath = path
            detected.fulfill()
        }

        provider.handleEvent(event(cwd: sibling.path))

        wait(for: [detected], timeout: 2)
        XCTAssertEqual(reportedPath, canon(sibling))
    }

    /// Once both are tracked, a nested worktree must win over its parent, or the
    /// pane's events keep being filed under the worktree it left.
    func testNestedWorktreeWinsOverItsParent() throws {
        let repo = root.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent(".claude/worktrees/feature")
        try makeDirectory(repo)
        try makeWorktreeRoot(nested)

        let provider = WebhookStatusProvider()
        provider.updateWorktrees([repo.path, nested.path])

        XCTAssertEqual(provider.matchWorktreeSync(canon(nested)), canon(nested))
        XCTAssertEqual(provider.matchWorktreeSync(canon(nested) + "/Sources"), canon(nested),
                       "a subdirectory of the nested worktree belongs to it, not to its parent")
        XCTAssertEqual(provider.matchWorktreeSync(canon(repo) + "/Sources"), canon(repo))
    }

    /// The cwd check runs on every hook event, and agents emit a lot of them, so
    /// an agent sitting in a not-yet-integrated worktree must not re-trigger
    /// discovery on every tool call.
    func testRepeatedEventsAskForDiscoveryOnce() throws {
        let repo = root.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent(".claude/worktrees/feature")
        try makeDirectory(repo)
        try makeWorktreeRoot(nested)

        let provider = WebhookStatusProvider()
        provider.updateWorktrees([repo.path])

        var calls = 0
        let first = expectation(description: "first request")
        provider.onNewWorktreeDetected = { _, _ in
            calls += 1
            if calls == 1 { first.fulfill() }
        }

        for _ in 0..<5 { provider.handleEvent(event(cwd: nested.path)) }

        wait(for: [first], timeout: 2)
        // Drain anything else the five events queued before asserting.
        let settle = expectation(description: "settle")
        DispatchQueue.main.async { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(calls, 1, "discovery was requested \(calls) times for one worktree")
    }

    /// A hook that carries no pane id still gets the worktree discovered; only
    /// the pane move is skipped, since we would not know which pane to move.
    func testMissingPaneIdStillReportsTheWorktree() throws {
        let repo = root.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent(".claude/worktrees/feature")
        try makeDirectory(repo)
        try makeWorktreeRoot(nested)

        let provider = WebhookStatusProvider()
        provider.updateWorktrees([repo.path])

        let detected = expectation(description: "reported")
        var reportedPane: String? = "unset"
        provider.onNewWorktreeDetected = { _, paneId in
            reportedPane = paneId
            detected.fulfill()
        }

        provider.handleEvent(event(cwd: nested.path, paneId: nil))

        wait(for: [detected], timeout: 2)
        XCTAssertNil(reportedPane)
    }
    // MARK: - The live attribution signal

    /// The untracked-worktree check only holds until the 5s discovery sweep
    /// integrates the worktree. An agent whose directory change is not itself a
    /// tool call reports its new cwd well after that, so every event has to say
    /// where the pane's agent is — including for worktrees already tracked.
    func testEveryEventReportsThePanesCurrentWorktree() throws {
        let repo = root.appendingPathComponent("repo")
        let other = root.appendingPathComponent("repo-worktrees/feature")
        try makeDirectory(repo)
        try makeWorktreeRoot(other)

        let provider = WebhookStatusProvider()
        provider.updateWorktrees([repo.path, other.path])

        let resolved = expectation(description: "pane worktree reported")
        var reportedPane: String?
        var reportedPath: String?
        provider.onPaneWorktreeResolved = { paneId, path in
            reportedPane = paneId
            reportedPath = path
            resolved.fulfill()
        }

        provider.handleEvent(event(cwd: other.path))

        wait(for: [resolved], timeout: 2)
        XCTAssertEqual(reportedPane, "seahelm-repo-main")
        XCTAssertEqual(reportedPath, canon(other))
    }

    /// A subagent's `agent_id` marks a nested context. One working in another
    /// directory must not drag the pane its parent is sitting in.
    func testSubagentEventsDoNotReportAPaneMove() throws {
        let repo = root.appendingPathComponent("repo")
        try makeDirectory(repo)

        let provider = WebhookStatusProvider()
        provider.updateWorktrees([repo.path])

        let notReported = expectation(description: "no move reported")
        notReported.isInverted = true
        provider.onPaneWorktreeResolved = { _, _ in notReported.fulfill() }

        provider.handleEvent(WebhookEvent(
            source: "claude-code", sessionId: "s1", event: .toolUseEnd,
            cwd: repo.path, timestamp: nil,
            data: ["tool_name": "Bash", "agent_id": "sub-1"],
            paneId: "seahelm-repo-main"))

        wait(for: [notReported], timeout: 0.6)
    }

    /// An event with no pane id cannot be attributed to a pane, so it must not
    /// claim one.
    func testEventWithoutAPaneIdReportsNoMove() throws {
        let repo = root.appendingPathComponent("repo")
        try makeDirectory(repo)

        let provider = WebhookStatusProvider()
        provider.updateWorktrees([repo.path])

        let notReported = expectation(description: "no move reported")
        notReported.isInverted = true
        provider.onPaneWorktreeResolved = { _, _ in notReported.fulfill() }

        provider.handleEvent(event(cwd: repo.path, paneId: nil))

        wait(for: [notReported], timeout: 0.6)
    }

    /// Not edge-cached: a move that the owner could not complete on the first
    /// event has to be retried on the next one, so the signal must repeat.
    func testTheSignalRepeatsRatherThanFiringOnce() throws {
        let repo = root.appendingPathComponent("repo")
        try makeDirectory(repo)

        let provider = WebhookStatusProvider()
        provider.updateWorktrees([repo.path])

        var calls = 0
        let twice = expectation(description: "reported for both events")
        twice.expectedFulfillmentCount = 2
        provider.onPaneWorktreeResolved = { _, _ in
            calls += 1
            twice.fulfill()
        }

        provider.handleEvent(event(cwd: repo.path))
        provider.handleEvent(event(cwd: repo.path))

        wait(for: [twice], timeout: 2)
        XCTAssertEqual(calls, 2)
    }

}
