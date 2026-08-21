import XCTest
@testable import seahelm

final class ManifestEngineTests: XCTestCase {

    private func manifest(_ json: String) throws -> CompiledManifest {
        let m = try JSONDecoder().decode(AgentManifest.self, from: Data(json.utf8))
        return CompiledManifest(try m.validated())
    }

    /// Regression: every bundled agent manifest must detect a braille-spinner OSC
    /// title as running. Previously only claude had this rule, so codex (and
    /// others) showed idle while "thinking" (spinner in title, static viewport).
    func testAllBundledManifestsDetectSpinnerTitle() {
        let store = ManifestStore.shared
        for id in ["claude", "codex", "opencode", "gemini", "cline", "goose",
                   "amp", "aider", "cursor", "kiro", "pi", "agent"] {
            guard let cm = store.manifest(for: id) else { XCTFail("missing \(id)"); continue }
            let d = cm.evaluate(DetectionInput(screen: "", oscTitle: "\u{2810} 调查查询服务不稳定的问题"))
            XCTAssertEqual(d.state, .running, "\(id) did not detect the spinner title as running")
            XCTAssertTrue(d.visibleWorking, "\(id) spinner should be visible_working")
        }
    }

    /// Cursor animates an hourglass label in its OSC title
    /// (`<chat name> - ⏳ Working ...`) rather than the braille spinner the shared
    /// `osc_title_working` rule expects, so that rule never fired and a working
    /// pane read as idle.
    func testCursorHourglassTitleDetectsAsRunning() {
        guard let cm = ManifestStore.shared.manifest(for: "cursor") else {
            return XCTFail("missing cursor manifest")
        }
        let working = cm.evaluate(DetectionInput(
            screen: "", oscTitle: "Tauri Performance Check - \u{23F3} Working .\u{00B7}\u{00B7}"))
        XCTAssertEqual(working.state, .running)
        XCTAssertTrue(working.visibleWorking)

        // A plain cwd title (Cursor's idle state) must not read as running.
        let idle = cm.evaluate(DetectionInput(
            screen: "", oscTitle: "/Volumes/openbeta/workspace/teamclaw"))
        XCTAssertNotEqual(idle.state, .running)
    }

    /// Pi has no text permission prompts (it uses a project-trust model) and a
    /// spinner-with-message working line ending "… to cancel". Verify the manifest
    /// maps the trust prompt to waiting and the working line to running.
    func testPiManifestDetection() {
        guard let cm = ManifestStore.shared.manifest(for: "pi") else {
            return XCTFail("missing pi manifest")
        }
        // The caller lowercases the viewport before evaluating, so tests do too.
        let trust = cm.evaluate(DetectionInput(screen: "project trust\n/users/me/proj\n↑↓ navigate  save  cancel", oscTitle: ""))
        XCTAssertEqual(trust.state, .waiting, "pi trust prompt should be waiting")
        XCTAssertTrue(trust.visibleBlocker)
        let working = cm.evaluate(DetectionInput(screen: "summarizing branch... (ctrl+c to cancel)", oscTitle: ""))
        XCTAssertEqual(working.state, .running, "pi working line should be running")
        // "pi" alias resolves to the same manifest.
        XCTAssertNotNil(ManifestStore.shared.manifest(for: "pi-coding-agent"))
    }

    /// Claude Code at an idle prompt with background work of its own (footer
    /// "· 1 shell ·", "· 1 monitor ·", or a spinner line ending "1 shell still
    /// running") must be reported as background-busy, so the dashboard still
    /// draws the worktree as busy rather than done.
    ///
    /// It is deliberately NOT the agent's status any more. A monitor lives as long
    /// as the thing it watches, so folding it into `state` pinned the pane on
    /// `running` indefinitely — and a pane that never leaves running never emits
    /// the running → idle edge that notifications ride on. `displayStatus` is what
    /// preserves the original dashboard behaviour; see `PaneInfoDisplayStatusTests`.
    func testClaudeBackgroundTasksDetectAsBackgroundBusy() {
        guard let cm = ManifestStore.shared.manifest(for: "claude") else {
            return XCTFail("missing claude manifest")
        }
        let footers = [
            "some transcript text\n\n❯ \n▸▸ bypass permissions on · 1 shell · ← 2 agents",
            "some transcript text\n\n❯ \n▸▸ bypass permissions on · 2 shells",
            "* sautéed for 2m 10s · 1 shell still running\n\n❯ \ncontext 6%",
            // Several kinds of background task are comma-separated, so the count is
            // no longer followed by "·" or end-of-line — the footer that made a
            // watching-CI pane report Idle on the dashboard.
            "some text\n\n❯ \n▸▸ bypass permissions on · pr #4902 · 1 shell, 1 monitor · ← 3 agents",
            // A monitor with no shell: "shell" never appears at all.
            "some text\n\n❯ \n▸▸ bypass permissions on · 1 monitor · ← 3 agents",
        ]
        for screen in footers {
            let d = cm.evaluate(DetectionInput(screen: screen.lowercased()))
            XCTAssertTrue(d.backgroundBusy, "expected background-busy for: \(screen)")
            XCTAssertNotEqual(d.state, .running,
                              "background work must not decide the agent's own status: \(screen)")
        }
        // Idle prompts must NOT match: "← 2 agents" is a persistent connected-
        // agents indicator (not a background task), and transcript prose like
        // "ran 2 shell commands" above the prompt is not a footer signal.
        let idles = [
            "ran 2 shell commands\ndone.\n\n❯ \n▸▸ bypass permissions on",
            "done.\n\n❯ \n▸▸ bypass permissions on (shift+tab to cycle) · ← 2 agents",
        ]
        for screen in idles {
            let d = cm.evaluate(DetectionInput(screen: screen))
            XCTAssertEqual(d.state, .unknown, "expected no match for: \(screen)")
            XCTAssertFalse(d.backgroundBusy, "expected no background work for: \(screen)")
        }
    }

    /// A background rule must not shadow the rule that answers the real question.
    /// Evaluation used to stop at the first match, so a footer shell count hid a
    /// live spinner (and anything else below its priority) behind `running` — the
    /// right answer by luck, the wrong reason, and wrong the moment the agent
    /// stopped.
    func testBackgroundRuleDoesNotShadowTheStatusRule() {
        guard let cm = ManifestStore.shared.manifest(for: "claude") else {
            return XCTFail("missing claude manifest")
        }
        let screen = """
        do you want to proceed?
        ❯ 
        ▸▸ bypass permissions on · 1 shell · ← 2 agents
        """
        let d = cm.evaluate(DetectionInput(screen: screen))
        XCTAssertEqual(d.state, .waiting, "a blocked agent still reads as waiting")
        XCTAssertTrue(d.backgroundBusy, "and the background work is still reported")
    }

    /// Regression: Claude Code no longer prints "esc to interrupt" in its spinner
    /// line, so `working_interrupt` stopped matching and every working pane fell
    /// through to the idle default. The spinner shape ("Verb… (3m 55s · ↓ 11.1k
    /// tokens)") must detect as running; the completion marker Claude replaces it
    /// with ("✻ Sautéed for 6m 25s" — no ellipsis, no parenthesised duration)
    /// must not.
    func testClaudeSpinnerWithoutInterruptHintDetectsAsRunning() {
        guard let cm = ManifestStore.shared.manifest(for: "claude") else {
            return XCTFail("missing claude manifest")
        }
        let footer = """

            ───────────────────────────────
            ❯
            ───────────────────────────────
              [opus 4.8 (1m context)] │ seahelm git:(fix/notification-unique-identifier*)
              context ██░░░░ 38% │ usage █░░░░░ 11% (resets in 3h 51m)
              ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 3 agents
            """
        // Captured verbatim from live panes (zmx history), lowercased as the
        // publisher does before evaluating.
        let working = [
            "· sprouting… (3m 55s · ↓ 11.1k tokens)",
            "✻ sprouting… (26s · ↓ 762 tokens)",
            "✳ cogitating... (1h 2m · ↑ 3 tokens)",
        ]
        for spinner in working {
            let d = cm.evaluate(DetectionInput(screen: (spinner + footer).lowercased()))
            XCTAssertEqual(d.state, .running, "expected running for: \(spinner)")
            XCTAssertTrue(d.visibleWorking)
        }
        // Completion markers and prose must not match.
        let done = [
            "✻ sautéed for 6m 25s",
            "✻ worked for 37s",
            "✻ brewed for 1m 3s",
            "* crunched for 2m 30s",
            "reading 1 file, running 1 shell command…",
        ]
        for marker in done {
            XCTAssertEqual(cm.evaluate(DetectionInput(screen: (marker + footer).lowercased())).state,
                           .unknown, "expected no match for: \(marker)")
        }
    }

    /// Regression: a multi-pane Claude worktree (short nested split) can push the
    /// `Thundering… (5m · ↓ tokens)` spinner above `bottom_lines:12`, leaving only
    /// the tool-progress line (`Running 2 shell commands · 53s…`) and the idle-
    /// looking footer visible. Without matching that tool line — and without
    /// seeing the spinner anywhere on the screen — First Mate shows a static
    /// idle circle while the pane is clearly working.
    func testClaudeToolProgressAndBuriedSpinnerDetectAsRunning() {
        guard let cm = ManifestStore.shared.manifest(for: "claude") else {
            return XCTFail("missing claude manifest")
        }
        let footer = """

            ───────────────────────────────
            ❯
            ───────────────────────────────
              [opus 5 (1m context)]
              teamclaw git:(chore/guard-against-stray-file-commits*)
              ⏵⏵ bypass permissions on (shift+tab to cycle) · pr #662 · ← 3 agents
            """
        // Live capture from seahelm-workspace-teamclaw-3: tool line without the
        // paren-duration spinner shape.
        let toolOnly = """
            running 2 shell commands · 53s…
              ⎿  $ cargo test -p amuxd --manifest-path apps/daemon/cargo.toml
                 (ctrl+b to run in background)
            \(footer)
            """.lowercased()
        let dTool = cm.evaluate(DetectionInput(screen: toolOnly))
        XCTAssertEqual(dTool.state, .running, "expected running for tool-progress line")
        XCTAssertTrue(dTool.visibleWorking)

        // Spinner buried under >12 lines of shell output — still on screen, but
        // outside bottom_lines:12.
        var buried = (0..<20).map { "[cron] scheduler gen \($0) stopped (current: 20)" }
            .joined(separator: "\n")
        buried += "\n✢ thundering… (5m 33s · ↓ 15.7k tokens)\n"
        buried += (0..<14).map { _ in "  ⎿  cargo test output line" }.joined(separator: "\n")
        buried += footer
        let dBuried = cm.evaluate(DetectionInput(screen: buried.lowercased()))
        XCTAssertEqual(dBuried.state, .running, "spinner above bottom_lines:12 must still match")
        XCTAssertTrue(dBuried.visibleWorking)

        // Footer alone (idle prompt) must stay unmatched.
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: footer.lowercased())).state, .unknown)
    }

    /// Regression: Cursor Agent CLI (entrypoint `agent`) no longer prints
    /// "to interrupt". Live panes show "ctrl+c to stop" plus a status line
    /// ("Working" / "Grepping  83.03k tokens"). Without these rules the sidebar
    /// stuck on idle/unknown while the process was clearly busy.
    func testCursorAgentCLIWorkingSignalsDetectAsRunning() {
        guard let cm = ManifestStore.shared.manifest(for: "cursor") else {
            return XCTFail("missing cursor manifest")
        }
        // Captured from live zmx history (lowercased as StatusPublisher does).
        let workingScreens = [
            """
            ✶ grepping  83.03k tokens
                tip: use /mcp to connect cursor to your tools and data sources.
              ❯ add a follow-up                                     ctrl+c to stop
              auto · 62.1% · 8 files edited                         run everything
            """,
            """
            ✶ working
              ❯ add a follow-up                                     ctrl+c to stop
              auto · 27% · 5 files edited                           run everything
            """,
            """
            ✶ updating  17.71k tokens
              ❯ add a follow-up                                     ctrl+c to stop
            """,
            // Older CLI builds kept the interrupt hint.
            "esc to interrupt\n(thinking)",
        ]
        for screen in workingScreens {
            let d = cm.evaluate(DetectionInput(screen: screen.lowercased()))
            XCTAssertEqual(d.state, .running, "expected running for:\n\(screen)")
            XCTAssertTrue(d.visibleWorking)
        }

        // Idle follow-up prompt: no ctrl+c to stop, no token spinner.
        let idle = """
            ❯ add a follow-up
            auto · 17.5%                                          run everything
            """
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: idle.lowercased())).state, .unknown,
                       "idle follow-up must not match running rules")
        // Todo list prose must not trip the Working status-line rule.
        let todoProse = "to-do working on 1 to-do · 1 done\n❯ add a follow-up"
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: todoProse.lowercased())).state, .unknown,
                       "todo 'Working on' must not match bare Working status line")
    }

    func testHighestPriorityWins() throws {
        // Two rules match; the higher-priority (waiting) must win over running.
        let cm = try manifest("""
        { "id": "t", "default_status": "idle", "rules": [
          { "id": "run", "state": "running", "priority": 100, "region": "whole_recent", "contains": ["to interrupt"] },
          { "id": "wait", "state": "waiting", "priority": 900, "region": "whole_recent", "contains": ["(y/n)"] }
        ]}
        """)
        let d = cm.evaluate(DetectionInput(screen: "esc to interrupt ... proceed? (y/n)"))
        XCTAssertEqual(d.state, .waiting)
        XCTAssertEqual(d.matchedRuleId, "wait")
    }

    func testNoMatchReturnsUnknownThenDefault() throws {
        let cm = try manifest("""
        { "id": "t", "default_status": "idle", "rules": [
          { "id": "run", "state": "running", "priority": 100, "region": "whole_recent", "contains": ["to interrupt"] }
        ]}
        """)
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: "nothing here")).state, .unknown)
        XCTAssertEqual(cm.defaultStatus, .idle)
    }

    func testAnyGate() throws {
        let cm = try manifest("""
        { "id": "t", "default_status": "idle", "rules": [
          { "id": "perm", "state": "waiting", "priority": 500, "region": "whole_recent",
            "any": [ { "contains": ["yes, proceed"] }, { "contains": ["(yes/no)"] } ] }
        ]}
        """)
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: "1. yes, proceed")).state, .waiting)
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: "run this? (yes/no)")).state, .waiting)
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: "unrelated")).state, .unknown)
    }

    func testNotGateBlocks() throws {
        let cm = try manifest("""
        { "id": "t", "default_status": "idle", "rules": [
          { "id": "run", "state": "running", "priority": 500, "region": "whole_recent",
            "contains": ["working"], "not": [ { "contains": ["done"] } ] }
        ]}
        """)
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: "working hard")).state, .running)
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: "working done")).state, .unknown)
    }

    func testRegionBottomLinesIgnoresOldOutput() throws {
        // "error:" is far above; bottom_lines:2 must not see it.
        let cm = try manifest("""
        { "id": "t", "default_status": "idle", "rules": [
          { "id": "err", "state": "error", "priority": 700, "region": "bottom_lines:2", "contains": ["error:"] }
        ]}
        """)
        let screen = "error: old failure\nline1\nline2\nline3"
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: screen)).state, .unknown)
        let screen2 = "ok\nerror: fresh"
        XCTAssertEqual(cm.evaluate(DetectionInput(screen: screen2)).state, .error)
    }

    func testOscTitleRegion() throws {
        let cm = try manifest("""
        { "id": "t", "default_status": "idle", "rules": [
          { "id": "spin", "state": "running", "priority": 1100, "region": "osc_title",
            "regex": ["^[\\\\x{2800}-\\\\x{28FF}] "], "visible_working": true }
        ]}
        """)
        let d = cm.evaluate(DetectionInput(screen: "", oscTitle: "\u{2807} Working…"))
        XCTAssertEqual(d.state, .running)
        XCTAssertTrue(d.visibleWorking)
    }

    func testSkipStateUpdateFlagCarried() throws {
        let cm = try manifest("""
        { "id": "t", "default_status": "idle", "rules": [
          { "id": "viewer", "state": "idle", "priority": 300, "region": "whole_recent",
            "contains": ["show transcript"], "skip_state_update": true }
        ]}
        """)
        let d = cm.evaluate(DetectionInput(screen: "show transcript"))
        XCTAssertTrue(d.skipStateUpdate)
        XCTAssertEqual(d.matchedRuleId, "viewer")
    }

    func testEngineVersionGuardRejects() throws {
        let m = try JSONDecoder().decode(AgentManifest.self, from: Data("""
        { "id": "t", "min_engine_version": 999, "rules": [] }
        """.utf8))
        XCTAssertThrowsError(try m.validated())
    }

    func testStatusMapping() {
        XCTAssertEqual(AgentStatus.fromManifest("working"), .running)
        XCTAssertEqual(AgentStatus.fromManifest("blocked"), .waiting)
        XCTAssertEqual(AgentStatus.fromManifest("IDLE"), .idle)
    }

    /// Evidence must name the line that actually fired, not the whole region —
    /// the wrong line sends you rewriting a rule that was innocent.
    func testMatchDetailNarrowsEvidenceToTheMatchingLine() {
        guard let cm = ManifestStore.shared.manifest(for: "claude") else {
            return XCTFail("missing claude manifest")
        }
        let screen = """
        ⏺ read(sources/status/manifestengine.swift)
        ✳ synthesizing… (12m 12s · ↓ 36.4k tokens)
          ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 5 agents
        """
        let detail = cm.matchDetail(DetectionInput(screen: screen))
        XCTAssertEqual(detail?.rule.id, "working_spinner")
        XCTAssertEqual(detail?.regionText, "✳ synthesizing… (12m 12s · ↓ 36.4k tokens)")
    }
}
