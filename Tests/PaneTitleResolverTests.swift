import XCTest
@testable import seahelm

final class PaneTitleResolverTests: XCTestCase {
    func testAgentPrefersSessionTitle() {
        let station = Station()
        guard let ref = AgentSessionRef(agent: "claude", sessionId: "abc-123") else {
            return XCTFail("expected valid AgentSessionRef")
        }
        station.agentSessionRef = ref
        var sailor = makeSailor(
            agentType: .claudeCode,
            prompt: "old prompt",
            branch: "feat/x",
            commandLine: nil
        )
        sailor.station = station
        let title = PaneTitleResolver.title(
            for: sailor,
            sessionTitle: { _, _ in "Fix login flake" },
            worktreeSessionTitle: { _ in nil }
        )
        XCTAssertEqual(title, "Fix login flake")
    }

    func testWorktreeSessionTitleBeforePrompt() {
        let sailor = makeSailor(agentType: .cursor, prompt: "Do the thing", branch: "feat/x")
        XCTAssertEqual(
            PaneTitleResolver.title(
                for: sailor,
                sessionTitle: { _, _ in nil },
                worktreeSessionTitle: { _ in "Check Error Logs" }
            ),
            "Check Error Logs"
        )
    }

    func testShellIgnoresWorktreeSessionTitle() {
        let sailor = makeSailor(
            agentType: .shellCommand,
            prompt: "",
            branch: "main",
            commandLine: "brew update"
        )
        XCTAssertEqual(
            PaneTitleResolver.title(
                for: sailor,
                sessionTitle: { _, _ in nil },
                worktreeSessionTitle: { _ in "Seahelm Layout Redesign" }
            ),
            "brew update"
        )
    }

    func testAgentFallsBackToPromptThenBranch() {
        var sailor = makeSailor(agentType: .claudeCode, prompt: "Do the thing", branch: "feat/x")
        XCTAssertEqual(
            PaneTitleResolver.title(
                for: sailor,
                sessionTitle: { _, _ in nil },
                worktreeSessionTitle: { _ in nil }
            ),
            "Do the thing"
        )
        sailor.lastUserPrompt = ""
        XCTAssertEqual(
            PaneTitleResolver.title(
                for: sailor,
                sessionTitle: { _, _ in nil },
                worktreeSessionTitle: { _ in nil }
            ),
            "feat/x"
        )
    }

    func testShellPrefersCommandThenWorktreePathNotWanderingPwd() {
        let station = Station()
        station.setPwd("/Users/me/.cursor/plugins/cache/foo")
        var sailor = makeSailor(
            agentType: .shellCommand,
            prompt: "",
            branch: "",
            commandLine: "git status",
            worktreePath: "/Users/me/proj"
        )
        sailor.station = station
        XCTAssertEqual(
            PaneTitleResolver.title(
                for: sailor,
                sessionTitle: { _, _ in nil },
                worktreeSessionTitle: { _ in nil }
            ),
            "git status"
        )

        sailor.commandLine = nil
        let title = PaneTitleResolver.title(
            for: sailor,
            sessionTitle: { _, _ in nil },
            worktreeSessionTitle: { _ in nil },
            pathDisplay: { path in path == "/Users/me/proj" ? "~/proj" : path }
        )
        // Wandering tool cwd must not become the title.
        XCTAssertEqual(title, "~/proj")
    }

    func testAgentIgnoresShellCommandLine() {
        let sailor = makeSailor(
            agentType: .cursor,
            prompt: "",
            branch: "ops/rds-cpu-degrade",
            commandLine: "cd ~/.cursor/plugins/cache"
        )
        XCTAssertEqual(
            PaneTitleResolver.title(
                for: sailor,
                sessionTitle: { _, _ in nil },
                worktreeSessionTitle: { _ in nil }
            ),
            "ops/rds-cpu-degrade"
        )
    }

    func testShellUsesCommandLineEvenWhenSiblingIsAgent() {
        // Per-pane: shellCommand must win over branch even if an agent shares
        // the worktree (isAgentPane must not use worktree-scoped agent type).
        let sailor = makeSailor(
            agentType: .shellCommand,
            prompt: "",
            branch: "main",
            commandLine: "brew update"
        )
        XCTAssertEqual(
            PaneTitleResolver.title(
                for: sailor,
                sessionTitle: { _, _ in nil },
                worktreeSessionTitle: { _ in "Cursor Session Title" }
            ),
            "brew update"
        )
    }

    func testShortenPathReplacesHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(PaneTitleResolver.shortenPath(home), "~")
        XCTAssertEqual(PaneTitleResolver.shortenPath(home + "/code/seahelm"), "~/code/seahelm")
        XCTAssertEqual(PaneTitleResolver.shortenPath("/tmp/x"), "/tmp/x")
    }

    func testFocusedStationIdUsesFocusedLeafElseFirst() {
        let a = "station-a"
        let leafA = UUID().uuidString
        let tree = SplitTree(worktreePath: "/wt", rootLeafId: leafA, stationId: a, sessionName: "")
        XCTAssertEqual(PaneTitleResolver.focusedStationId(in: tree), a)
        tree.focusedId = "missing"
        XCTAssertEqual(PaneTitleResolver.focusedStationId(in: tree), a)
    }

    /// Sibling agent panes in one worktree share every other title source, so
    /// the per-pane OSC title has to win or switching panes changes nothing.
    func testAgentPrefersOscTitleOverWorktreeSessionTitle() {
        let station = Station()
        station.setOscTitle("✳ 修复重启后的onboarding重复弹出")
        var sailor = makeSailor(agentType: .claudeCode, prompt: "old prompt", branch: "main")
        sailor.station = station
        XCTAssertEqual(
            PaneTitleResolver.title(
                for: sailor,
                sessionTitle: { _, _ in nil },
                worktreeSessionTitle: { _ in "Shared Worktree Title" }
            ),
            "修复重启后的onboarding重复弹出"
        )
    }

    func testOscSpinnerFramesResolveToStableTitle() {
        // The leading glyph animates; the header must not churn with it.
        let titles = ["✳ Update title", "⠐ Update title", "⠂ Update title", "   Update title"]
        for raw in titles {
            let station = Station()
            station.setOscTitle(raw)
            var sailor = makeSailor(agentType: .claudeCode, prompt: "p", branch: "main")
            sailor.station = station
            XCTAssertEqual(
                PaneTitleResolver.title(
                    for: sailor,
                    sessionTitle: { _, _ in nil },
                    worktreeSessionTitle: { _ in nil }
                ),
                "Update title",
                "failed for \(raw)"
            )
        }
    }

    func testOscTitleIgnoredForShellAndWhenItIsJustThePath() {
        // Shell panes keep using the command line.
        let shellStation = Station()
        shellStation.setOscTitle("some-shell-title")
        var shell = makeSailor(
            agentType: .shellCommand, prompt: "", branch: "main", commandLine: "brew update"
        )
        shell.station = shellStation
        XCTAssertEqual(
            PaneTitleResolver.title(
                for: shell,
                sessionTitle: { _, _ in nil },
                worktreeSessionTitle: { _ in nil }
            ),
            "brew update"
        )

        // An agent parking the cwd in the title falls through to the real chain.
        let agentStation = Station()
        agentStation.setOscTitle("/tmp/wt")
        var agent = makeSailor(agentType: .claudeCode, prompt: "", branch: "feat/x")
        agent.station = agentStation
        XCTAssertEqual(
            PaneTitleResolver.title(
                for: agent,
                sessionTitle: { _, _ in nil },
                worktreeSessionTitle: { _ in nil }
            ),
            "feat/x"
        )
    }

    func testFocusedStationIdIsNilWithoutTree() {
        XCTAssertNil(PaneTitleResolver.focusedStationId(in: nil))
    }

    func testFocusedStationIdTracksFocusAcrossSplit() {
        // The "current pane" the chrome header and First Mate both follow: with
        // several leaves it must be the focused one, not simply the first.
        let leafA = UUID().uuidString
        let tree = SplitTree(worktreePath: "/wt", rootLeafId: leafA, stationId: "station-a", sessionName: "")
        let leafB = UUID().uuidString
        _ = tree.splitFocusedLeaf(
            axis: .vertical,
            newLeafId: leafB,
            newStationId: "station-b",
            newSessionName: "s2"
        )

        tree.focusedId = leafB
        XCTAssertEqual(PaneTitleResolver.focusedStationId(in: tree), "station-b")

        tree.focusedId = leafA
        XCTAssertEqual(PaneTitleResolver.focusedStationId(in: tree), "station-a")

        // Stale focus id (pane closed underneath) degrades to the first leaf.
        tree.focusedId = "gone"
        XCTAssertEqual(PaneTitleResolver.focusedStationId(in: tree), "station-a")
    }

    // MARK: - Helpers

    private func makeSailor(
        agentType: SailorType,
        prompt: String,
        branch: String,
        commandLine: String? = nil,
        worktreePath: String = "/tmp/wt"
    ) -> SailorInfo {
        SailorInfo(
            id: UUID().uuidString,
            worktreePath: worktreePath,
            agentType: agentType,
            project: "proj",
            branch: branch,
            status: .idle,
            lastMessage: "",
            lastUserPrompt: prompt,
            commandLine: commandLine,
            roundDuration: 0,
            startedAt: nil,
            station: nil,
            channel: nil,
            taskProgress: TaskProgress()
        )
    }
}
