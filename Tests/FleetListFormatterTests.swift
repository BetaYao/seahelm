import XCTest
@testable import seahelm

/// The fleet listing and `/pane <n>` share one numbering; these pin that they
/// cannot disagree, because the number is all a chat or mail reply gives you.
final class FleetListFormatterTests: XCTestCase {
    private let fleet = [
        AgentRef(id: "a", project: "seahelm", branch: "main", type: "Claude", title: "fix login",
                 status: .waiting, lastMessage: "Ready for your input"),
        AgentRef(id: "b", project: "seahelm", branch: "oauth", type: "Codex", title: "refactor",
                 status: .running, lastMessage: "Running tests"),
        AgentRef(id: "c", project: "other", branch: "main", type: "Claude", title: "docs",
                 status: .idle, lastMessage: ""),
    ]

    func testNumbersEveryPaneAcrossProjects() {
        let text = BridgeCommandFormatter.fleetList(fleet, currentId: nil)
        XCTAssertTrue(text.contains("1. "), text)
        XCTAssertTrue(text.contains("2. "), text)
        XCTAssertTrue(text.contains("3. "), text)
    }

    func testGroupsUnderProjectAndBranch() {
        let text = BridgeCommandFormatter.fleetList(fleet, currentId: nil)
        XCTAssertTrue(text.contains("**seahelm**"), text)
        XCTAssertTrue(text.contains("**other**"), text)
        XCTAssertTrue(text.contains("main"), text)
        XCTAssertTrue(text.contains("oauth"), text)
        // One project header even though it owns two worktrees.
        XCTAssertEqual(text.components(separatedBy: "**seahelm**").count - 1, 1, text)
    }

    func testMarksTheCurrentPane() {
        let text = BridgeCommandFormatter.fleetList(fleet, currentId: "b")
        let current = text.split(separator: "\n").first { $0.contains("← current") }
        XCTAssertNotNil(current)
        XCTAssertTrue(current?.contains("refactor") == true, String(current ?? ""))
    }

    /// The printed number must be exactly what the parser reads back, or
    /// `/pane 2` opens something other than the row the reader counted.
    func testPrintedNumbersResolveToTheSamePane() {
        for (offset, agent) in fleet.enumerated() {
            let parsed = BridgeCommandParser.parse("/pane \(offset + 1)", worktrees: [], agents: fleet)
            XCTAssertEqual(parsed, .success(.selectAgent(id: agent.id)), "row \(offset + 1)")
        }
    }

    /// `#` stays a valid selector, so the older `/pane #2` spelling keeps working.
    func testHashPrefixStillSelects() {
        XCTAssertEqual(BridgeCommandParser.parse("/pane #2", worktrees: [], agents: fleet),
                       .success(.selectAgent(id: "b")))
    }

    func testBarePaneListsRatherThanSelects() {
        XCTAssertEqual(BridgeCommandParser.parse("/pane", worktrees: [], agents: fleet),
                       .success(.listAgents))
    }

    /// A shell pane's title is its entire command line; left whole it wraps for
    /// several lines and destroys the alignment the numbering is read from.
    func testTruncatesRunawayTitles() {
        let long = String(repeating: "dart --vm-service-uri=http://127.0.0.1:60616/ ", count: 6)
        let rows = [AgentRef(id: "x", project: "p", branch: "b", type: "Shell", title: long, status: .idle)]
        for line in BridgeCommandFormatter.fleetList(rows, currentId: nil).split(separator: "\n") {
            XCTAssertLessThan(line.count, 100, "row wraps: \(line)")
        }
    }

    /// Panes with no session title fall back to the branch, which the line above
    /// already carries — repeating it is pure noise.
    func testOmitsATitleThatOnlyRepeatsTheBranch() {
        let rows = [AgentRef(id: "x", project: "p", branch: "main", type: "Unknown", title: "main", status: .idle)]
        let row = BridgeCommandFormatter.fleetList(rows, currentId: nil)
            .split(separator: "\n").first { $0.contains("1.") }
        XCTAssertEqual(row?.trimmingCharacters(in: .whitespaces), "1. ○ Unknown")
    }

    func testEmptyFleetExplainsHowToStartOne() {
        XCTAssertTrue(BridgeCommandFormatter.fleetList([], currentId: nil).contains("/worktree"))
    }

    // MARK: - Detail

    func testPaneDetailCarriesStatusLatestAndActivity() {
        let text = BridgeCommandFormatter.paneDetail(
            fleet[1], activity: ["Bash — swift test", "Read — main.swift"],
            transcript: "> ran the suite\n42 passed", joined: "Now steering it.")
        XCTAssertTrue(text.contains("Codex"), text)
        XCTAssertTrue(text.contains("refactor"), text)
        XCTAssertTrue(text.contains("seahelm / oauth"), text)
        XCTAssertTrue(text.contains("Running tests"), text)
        XCTAssertTrue(text.contains("Bash — swift test"), text)
        XCTAssertTrue(text.contains("Now steering it."), text)
        XCTAssertTrue(text.contains("42 passed"), "the session transcript leads the reply")
    }

    /// The status fields are empty for a pane that reports no structured events,
    /// which used to leave the reply with nothing in it — the scrollback is the
    /// only thing that always has something to say.
    func testPaneDetailCarriesTheSessionTranscript() {
        let text = BridgeCommandFormatter.paneDetail(
            fleet[2], activity: [], transcript: "$ swift build\nBuild complete", joined: "Bound.")
        XCTAssertTrue(text.contains("**Session**"), text)
        XCTAssertTrue(text.contains("Build complete"), text)
    }

    /// An agent TUI repaints meters, rules and a permission banner around the
    /// conversation; in a mail that furniture outweighs what was actually said.
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
        XCTAssertEqual(ZmxChannel.stripTerminalControl(raw), "real answer here\nsecond real line")
    }

    func testStripsTerminalControlSequences() {
        let raw = "\u{1B}[1;32mready\u{1B}[0m\n\u{1B}]0;title\u{07}\n────────\n$ ls"
        let clean = ZmxChannel.stripTerminalControl(raw)
        XCTAssertEqual(clean, "ready\n$ ls", clean)
    }

    func testPaneDetailOmitsEmptySections() {
        let text = BridgeCommandFormatter.paneDetail(fleet[2], activity: [], transcript: nil, joined: "Bound.")
        XCTAssertFalse(text.contains("Recent activity"), text)
        XCTAssertFalse(text.contains("Latest"), text)
        XCTAssertFalse(text.contains("**Session**"), text)
        XCTAssertTrue(text.contains("Bound."), text)
    }
}
