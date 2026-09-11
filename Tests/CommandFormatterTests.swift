import XCTest
@testable import seahelm

final class CommandFormatterTests: XCTestCase {
    private let index = CommandFixture.index

    // MARK: - Panes

    func testEveryPaneCarriesItsHandle() {
        let text = CommandFormatter.panes(index, bound: nil)
        for handle in ["#3 ", "#7 ", "#12 "] {
            XCTAssertTrue(text.contains(handle), text)
        }
        XCTAssertFalse(text.contains("1. "), "positional numbering is gone")
    }

    func testGroupsUnderRepoAndBranchOnce() {
        let text = CommandFormatter.panes(index, bound: nil)
        XCTAssertEqual(text.components(separatedBy: "**alpha**").count - 1, 1, text)
        XCTAssertEqual(text.components(separatedBy: "**beta**").count - 1, 1, text)
        XCTAssertTrue(text.contains("  feat-x"), text)
    }

    func testMarksTheBoundPane() {
        let text = CommandFormatter.panes(index, bound: CommandFixture.paneB)
        let marked = text.split(separator: "\n").filter { $0.contains("talking to this one") }
        XCTAssertEqual(marked.count, 1, text)
        XCTAssertTrue(marked.first?.contains("#7") == true, text)
    }

    /// The printed handle is exactly what the parser reads back.
    func testPrintedHandlesResolveToTheSamePane() {
        for pane in index.panes {
            XCTAssertEqual(try? CommandParser.parse("/go #\(pane.handle)", index: index).get().command,
                           .go(.pane(pane)))
        }
    }

    /// A shell pane's title is its entire command line; left whole it wraps for
    /// several lines and destroys the alignment.
    func testTruncatesRunawayTitles() {
        let long = String(repeating: "dart --vm-service-uri=http://127.0.0.1:60616/ ", count: 6)
        let fleet = FleetIndex(panes: [PaneRef(handle: 1, handleKey: "k", id: "x", project: "p", branch: "b",
                                               worktreePath: "/p/b", type: "Shell", title: long)])
        for line in CommandFormatter.panes(fleet, bound: nil).split(separator: "\n") {
            XCTAssertLessThan(line.count, 100, "row wraps: \(line)")
        }
    }

    /// A pane with no session title falls back to the branch, which the line
    /// above already carries — repeating it is pure noise.
    func testOmitsATitleThatOnlyRepeatsTheBranch() {
        let fleet = FleetIndex(panes: [PaneRef(handle: 4, handleKey: "k", id: "x", project: "p", branch: "main",
                                               worktreePath: "/p/main", type: "Unknown", title: "main", status: .idle)])
        let row = CommandFormatter.panes(fleet, bound: nil).split(separator: "\n").first { $0.contains("#4") }
        XCTAssertEqual(row?.trimmingCharacters(in: .whitespaces), "#4 ○ Unknown")
    }

    func testEmptyFleetExplainsHowToStartOne() {
        XCTAssertTrue(CommandFormatter.panes(.empty, bound: nil).contains("/new"))
    }

    /// An integration checkout sits on a detached HEAD, so it has no branch.
    /// Heading its group with that empty string printed a blank line, which
    /// reads as a formatting fault rather than as a worktree.
    func testDetachedWorktreeIsNamedAfterItsDirectory() {
        let fleet = FleetIndex(panes: [
            PaneRef(handle: 13, handleKey: "k", id: "x", project: "seahelm", branch: "",
                    worktreePath: "/w/seahelm-worktrees/integration", type: "Unknown",
                    title: "seahelm", status: .idle),
        ])
        let text = CommandFormatter.panes(fleet, bound: nil)
        XCTAssertTrue(text.contains("  integration"), text)
        XCTAssertFalse(text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).isEmpty
                            && $0.hasPrefix("  ") }, "blank group header: \(text)")
    }

    /// Two worktrees can carry the same branch name in different repos, and
    /// grouping by branch merged their panes into one heading.
    func testSameBranchInTwoWorktreesStaysTwoGroups() {
        let fleet = FleetIndex(panes: [
            PaneRef(handle: 1, handleKey: "a", id: "a", project: "p", branch: "main",
                    worktreePath: "/p/one", type: "Claude", title: "first", status: .idle),
            PaneRef(handle: 2, handleKey: "b", id: "b", project: "p", branch: "main",
                    worktreePath: "/p/two", type: "Claude", title: "second", status: .idle),
        ])
        let headings = CommandFormatter.panes(fleet, bound: nil)
            .split(separator: "\n").filter { $0.hasPrefix("  main") }
        XCTAssertEqual(headings.count, 2, "one heading per worktree")
    }

    // MARK: - Worktrees and repos

    /// `main` is in both repos, so the listing prints the form that parses.
    func testWorktreeListingDisambiguatesSharedBranchNames() {
        let text = CommandFormatter.worktrees(index, bound: nil)
        XCTAssertTrue(text.contains("@alpha/main"), text)
        XCTAssertTrue(text.contains("@beta/main"), text)
        XCTAssertTrue(text.contains("@feat-x"), text)
        XCTAssertFalse(text.contains("@alpha/feat-x"), "a unique branch keeps the short form")
        XCTAssertTrue(text.contains("2 panes"), text)
        XCTAssertTrue(text.contains("no panes"), text)
    }

    func testRepoListing() {
        let text = CommandFormatter.repos(index)
        XCTAssertTrue(text.contains("@alpha"), text)
        XCTAssertTrue(text.contains("/workspaces/beta"), text)
        XCTAssertTrue(text.contains("2 worktrees"), text)
    }

    // MARK: - Detail

    func testPaneDetailCarriesStatusLatestAndActivity() {
        let text = CommandFormatter.paneDetail(
            CommandFixture.paneB, activity: ["Bash — swift test", "Read — main.swift"],
            transcript: "> ran the suite\n42 passed", footer: "Bound.")
        XCTAssertTrue(text.contains("#7 alpha/feat-x"), text)
        XCTAssertTrue(text.contains("Codex"), text)
        XCTAssertTrue(text.contains("Running tests"), text)
        XCTAssertTrue(text.contains("Bash — swift test"), text)
        XCTAssertTrue(text.contains("42 passed"), "the session transcript leads the reply")
        XCTAssertTrue(text.hasSuffix("Bound."), text)
    }

    func testPaneDetailOmitsEmptySections() {
        let text = CommandFormatter.paneDetail(CommandFixture.paneC, activity: [], transcript: nil, footer: nil)
        XCTAssertFalse(text.contains("Recent activity"), text)
        XCTAssertFalse(text.contains("Latest"), text)
        XCTAssertFalse(text.contains("**Session**"), text)
    }

    /// A pane that has said nothing takes its title from the agent's own OSC
    /// title, and printing both reads as "Claude Code — Claude Code".
    func testPaneDetailDropsATitleThatIsJustTheAgentName() {
        let pane = PaneRef(handle: 26, handleKey: "k26", id: "d", sessionKey: "k26",
                           project: "saas-mono", branch: "task/betly-app", worktreePath: "/repo/betly",
                           type: "Claude Code", title: "claude code", status: .idle,
                           lastMessage: "Session started")
        let text = CommandFormatter.paneDetail(pane, activity: [], transcript: nil, footer: nil)
        XCTAssertTrue(text.contains("· Claude Code"), text)
        XCTAssertFalse(text.contains("—"), "the title repeats the agent name")
        XCTAssertFalse(text.contains("Latest"), "a lifecycle label is not the latest anything")
    }

    // MARK: - Errors

    func testErrorsSayHowToFindTheThing() {
        XCTAssertTrue(CommandFormatter.describe(.unknownPane(8)).contains("/status"))
        XCTAssertTrue(CommandFormatter.describe(.unknownWorktree("x")).contains("/status worktrees"))
        XCTAssertTrue(CommandFormatter.describe(.repoNotWorktree("alpha")).contains("/forget @alpha"))
        XCTAssertTrue(CommandFormatter.describe(.missingArgument(verb: "order", what: "the text")).contains("/order #pane <text>"))
        XCTAssertTrue(CommandFormatter.describe(.ambiguousWorktree("main", ["a/main", "b/main"])).contains("`@a/main`"))
    }

    // MARK: - Spec-driven help

    func testHelpListsEveryVerbOnce() {
        let help = CommandSpecs.help
        for spec in CommandSpecs.all {
            XCTAssertEqual(help.components(separatedBy: "`\(spec.usage)`").count - 1, 1, spec.verb)
        }
        XCTAssertTrue(help.contains("<anything>"), help)
        XCTAssertNil(CommandSpecs.help(for: "nope"))
        XCTAssertTrue(CommandSpecs.help(for: "return")?.contains("/yes") == true)
    }

    func testMailSignatureAndMenuComeFromTheSpecs() {
        XCTAssertEqual(MailSignature.entries.map(\.command), CommandSpecs.mailEntries.map(\.command))
        XCTAssertFalse(MailSignature.entries.contains { $0.command.hasPrefix("/add") }, "desktop-only verbs stay out of mail")
        XCTAssertFalse(CommandSpecs.menu.contains { $0.name == "yes" }, "the Helm line has sheets, not /yes")
        XCTAssertTrue(CommandSpecs.menu.contains { $0.name == "new" })
    }
    // MARK: - Listing buttons

    /// The button and the printed handle must mean the same pane: a phone taps
    /// what a laptop types.
    func testEveryPaneButtonIsALineTheParserReadsBack() {
        let buttons = CommandFormatter.paneButtons(index, bound: nil)
        XCTAssertEqual(buttons.count, index.panes.count)
        for button in buttons {
            guard case .line(let line) = button.effect else { return XCTFail("not a line: \(button)") }
            guard case .go(.pane(let pane))? = try? CommandParser.parse(line, index: index).get().command else {
                return XCTFail("did not parse to a pane: \(line)")
            }
            XCTAssertTrue(button.label.contains("#\(pane.handle)"), button.label)
        }
    }

    func testThePaneAlreadyBoundGetsNoButton() {
        let lines = CommandFormatter.paneButtons(index, bound: CommandFixture.paneB).map(\.effect)
        XCTAssertFalse(lines.contains(.line("/go #7")), "\(lines)")
        XCTAssertTrue(lines.contains(.line("/go #3")), "\(lines)")
    }

    /// A big fleet would bury its own listing under shortcuts; the text above
    /// still names every pane.
    func testButtonsAreCapped() {
        let panes = (1...30).map {
            PaneRef(handle: $0, handleKey: "k\($0)", id: "\($0)", project: "p", branch: "b\($0)",
                    worktreePath: "/p/b\($0)", type: "Claude", title: "")
        }
        let big = FleetIndex(panes: panes)
        XCTAssertEqual(CommandFormatter.paneButtons(big, bound: nil).count, CommandFormatter.buttonLimit)
    }

    /// `/go @somewhere-with-no-pane` has nothing to talk to, so it is not offered.
    func testWorktreeButtonsSkipTheOnesWithNoPane() {
        let buttons = CommandFormatter.worktreeButtons(index, bound: nil)
        XCTAssertEqual(buttons.map(\.label).sorted(), ["beta/main", "feat-x"])
        for button in buttons {
            guard case .line(let line) = button.effect else { return XCTFail("not a line: \(button)") }
            guard case .go(.worktree)? = try? CommandParser.parse(line, index: index).get().command else {
                return XCTFail("did not parse to a worktree: \(line)")
            }
        }
    }

    func testWorktreeButtonsSkipTheOneAlreadyHere() {
        let buttons = CommandFormatter.worktreeButtons(index, bound: CommandFixture.paneB)
        XCTAssertEqual(buttons.map(\.label), ["beta/main"])
    }

}
