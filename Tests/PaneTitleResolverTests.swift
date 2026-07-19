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
