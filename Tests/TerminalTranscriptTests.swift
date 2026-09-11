import XCTest
@testable import seahelm

final class TerminalTranscriptTests: XCTestCase {

    private let rule = String(repeating: "─", count: 40)

    func testStripsTerminalControlSequences() {
        let raw = "\u{1B}[1;32mready\u{1B}[0m\n\u{1B}]0;title\u{07}\n────────\n$ ls"
        XCTAssertEqual(TerminalTranscript.clean(raw), "ready\n$ ls")
    }

    /// An agent TUI repaints meters, rules and a permission banner around the
    /// conversation; read in a chat, that furniture outweighs what was said.
    func testStripsAgentTUIChrome() {
        let raw = [
            "real answer here",
            "❯",
            "✻ Churned for 44s",
            "Context █░░░░░░░░░ 7% │ Usage ██░░░░░░░░ 19% (resets in 2h)",
            "⏵⏵ bypass permissions on (shift+tab to cycle)",
            "⚠ Transcript saving is off — inherited marker",
            "::seahelm-suggest:: a | b",
            "second real line",
        ].joined(separator: "\n")
        XCTAssertEqual(TerminalTranscript.clean(raw), "real answer here\nsecond real line")
    }

    /// The verb in the churn line is picked at random, so it cannot be matched
    /// on: "Churned", "Worked", "Sautéed" are all the same line.
    func testStripsEveryChurnVerb() {
        let raw = "answer\n✻ Sautéed for 2m 28s · done 6:50 PM\n✻ Worked for 1m 7s"
        XCTAssertEqual(TerminalTranscript.clean(raw), "answer")
    }

    /// The control line wraps when it is wider than the pane, and the wrapped
    /// remainder carries no marker of its own.
    func testStripsAWrappedSuggestLine() {
        let raw = [
            "the answer",
            "::seahelm-suggest:: 授权后重跑 From 写入 | 开始做落库那部分改动 |",
            "给 issue 打 ai:auto 进自动队列 | 先查 1:1 失败的 58 条明细",
            "next real line",
        ].joined(separator: "\n")
        XCTAssertEqual(TerminalTranscript.clean(raw), "the answer\nnext real line")
    }

    // MARK: - The composer box

    /// Everything below the composer is the agent's own furniture, and the
    /// statusline down there is whatever command the user configured — no list
    /// of strings could keep up with it, so the cut is positional.
    func testCutsEverythingBelowTheComposerBox() {
        let raw = [
            "⏺ the answer",
            rule,
            "❯ 提 PR",
            rule,
            "[Opus 5 (1M context)] │ mei-yi-ge git:(task/mei-yi-ge)                    /rc",
            "Context ████░░ 41% │ Usage 7d: █████░ 49% (resets in 4d 7h)",
            "⏵⏵ bypass permissions on (shift+tab to cycle) · ← 5 agents",
            "⧉  apps-login-domain",
        ].joined(separator: "\n")
        // The composer's own text stays: it is the operator's words, unsent.
        XCTAssertEqual(TerminalTranscript.clean(raw), "⏺ the answer\n❯ 提 PR")
    }

    /// A lone rule is just as likely to be a markdown `---` the agent printed.
    /// Cutting there would throw away the answer, so the *pair* is the signal.
    func testKeepsProseBelowASingleRule() {
        let raw = ["## Findings", rule, "the part that matters", "and its conclusion"].joined(separator: "\n")
        XCTAssertEqual(TerminalTranscript.clean(raw), "## Findings\nthe part that matters\nand its conclusion")
    }

    /// A pane sitting at a shell has no composer box at all.
    func testKeepsAPlainShellCaptureWhole() {
        let raw = "warning: `teamclu` (lib) generated 1 warning\nBuilding 953/954"
        XCTAssertEqual(TerminalTranscript.clean(raw), raw)
    }

    // MARK: - The startup banner

    /// A pane that has just started — or just been `/clear`ed — is nothing but
    /// banner, notices and statusline. The whole capture should come back empty
    /// so `/show` leaves the section out rather than printing furniture.
    func testAFreshPaneHasNothingToShow() {
        let raw = [
            "▐▛███▛█   Claude Code v2.1.263",
            "▝▜██████▀  Opus 5 (1M context) with xhigh effort · Claude Max",
            "  ▝▝ ▝▝    /Volumes/openbeta/workspace/saas-mono-worktrees/task/https-github-com-bet",
            "⚠ 1 MCP server needs authentication · run /mcp",
            "✔ Update installed · Restart to update",
            rule,
            "❯",
            rule,
            "[Opus 5 (1M context)] │ https-github-com-bet git:(task/betly-app)          /rc",
            "Context ░░░░░░ 0% │ Usage 7d: ███░░░ 33% (resets in 3d 17h)",
            "⏵⏵ bypass permissions on (shift+tab to cycle) · ← 5 agents",
        ].joined(separator: "\n")
        XCTAssertEqual(TerminalTranscript.clean(raw), "")
    }

    /// One block glyph is a gutter, not a banner — Codex prefixes its own
    /// messages with `▌`, and that line is the message. The gutter itself is
    /// drawing, so it goes and the words stay.
    func testUnframesAGutteredMessage() {
        XCTAssertEqual(TerminalTranscript.clean("▌ the agent's own words"), "the agent's own words")
    }

    // MARK: - The other agents

    /// Cursor Agent puts its whole UI inside a box, a blocked pane's question
    /// included. Dropping every framed line — which is what a first-character
    /// test does — threw away the one thing worth reading from a phone.
    func testReadsCursorAgentsFramedDialog() {
        let raw = [
            "╭──────────────────────────────────────────────────────────────╮",
            "│                                                              │",
            "│  ⚠ Workspace Trust Required                                  │",
            "│                                                              │",
            "│  Do you trust the contents of this directory?                │",
            "│                                                              │",
            "│    [a] Trust this workspace                                  │",
            "│    [q] Quit                                                  │",
            "╰──────────────────────────────────────────────────────────────╯",
        ].joined(separator: "\n")
        XCTAssertEqual(TerminalTranscript.clean(raw), """
        ⚠ Workspace Trust Required
        Do you trust the contents of this directory?
        [a] Trust this workspace
        [q] Quit
        """)
    }

    /// OpenCode frames its composer with `┃` sides and a half-block floor, and
    /// hangs key hints, a tip and its statusline under it. None of those glyphs
    /// are the ones Claude Code draws with, which is why the rules take the box
    /// and block Unicode ranges whole.
    func testCutsOpenCodesFooter() {
        let raw = [
            "█▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█",
            "┃",
            "┃  Ask anything...",
            "╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀",
            "tab agents  ctrl+p commands",
            "● Tip Run /compact to summarize long sessions near context limits",
            "/private/tmp/probe:main            1.18.18",
        ].joined(separator: "\n")
        XCTAssertEqual(TerminalTranscript.clean(raw), "Ask anything...")
    }

    /// Codex draws no frame around its composer, so its startup box is the only
    /// pair of rules in the capture — and it sits eight rows up, with the tip
    /// and the MCP warnings below it. Reading that as a composer would take all
    /// of them down, so the cut only ever looks at the last few rows.
    func testDoesNotMistakeCodexsStartupBoxForAComposer() {
        let raw = [
            "╭───────────────────────────────────────────╮",
            "│ >_ OpenAI Codex (v0.153.4)                │",
            "│                                           │",
            "│ model:     gpt-5.6-luna xhigh             │",
            "╰───────────────────────────────────────────╯",
            "Tip: give it a hard problem, a half-formed idea,",
            "or anything you have been meaning to build.",
            "⚠ The supabase MCP server requires OAuth reauthentication.",
            "⚠ MCP startup incomplete (failed: supabase)",
            "› Ask Codex to do anything",
        ].joined(separator: "\n")
        let text = TerminalTranscript.clean(raw)
        XCTAssertTrue(text.contains("⚠ MCP startup incomplete (failed: supabase)"), text)
        XCTAssertTrue(text.hasPrefix(">_ OpenAI Codex (v0.153.4)"), text)
    }
}
