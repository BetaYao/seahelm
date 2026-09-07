import XCTest
@testable import seahelm

/// Shared fixture: two repos, an ambiguous `main`, three panes with handles.
enum CommandFixture {
    static let paneA = PaneRef(handle: 3, handleKey: "k3", id: "a", sessionKey: "k3",
                               project: "alpha", branch: "feat-x", worktreePath: "/repo/feat-x",
                               type: "Claude", title: "Wire up the parser", status: .waiting, lastMessage: "Ready for your input")
    static let paneB = PaneRef(handle: 7, handleKey: "k7", id: "b", sessionKey: "k7",
                               project: "alpha", branch: "feat-x", worktreePath: "/repo/feat-x",
                               type: "Codex", title: "Chase the flaky test", status: .running, lastMessage: "Running tests")
    static let paneC = PaneRef(handle: 12, handleKey: "k12", id: "c", sessionKey: "k12",
                               project: "beta", branch: "main", worktreePath: "/beta/main",
                               type: "Claude", title: "docs", status: .idle)

    static let alphaMain = WorktreeRef(repo: "alpha", branch: "main", path: "/alpha/main", isMain: true)
    static let featX = WorktreeRef(repo: "alpha", branch: "feat-x", path: "/repo/feat-x")
    static let betaMain = WorktreeRef(repo: "beta", branch: "main", path: "/beta/main", isMain: true)
    static let fixY = WorktreeRef(repo: "beta", branch: "fix-y", path: "/repo/fix-y")

    static let alpha = RepoRef(name: "alpha", path: "/workspaces/alpha")
    static let beta = RepoRef(name: "beta", path: "/workspaces/beta")

    static let index = FleetIndex(panes: [paneA, paneB, paneC],
                                  worktrees: [alphaMain, featX, betaMain, fixY],
                                  repos: [alpha, beta])
}

final class CommandParserTests: XCTestCase {
    private let index = CommandFixture.index

    private func parse(_ text: String) -> Result<ParsedLine, CommandError> {
        CommandParser.parse(text, index: index)
    }

    private func command(_ text: String) -> Command? {
        try? parse(text).get().command
    }

    private func error(_ text: String) -> CommandError? {
        if case .failure(let e) = parse(text) { return e }
        return nil
    }

    // MARK: - Prose

    func testBareTextIsSaidToTheBoundPane() {
        XCTAssertEqual(command("fix the flaky test"), .say("fix the flaky test"))
    }

    func testEmptyIsAnError() {
        XCTAssertEqual(error("   "), .empty)
    }

    // MARK: - /new

    func testNewTakesATask() {
        XCTAssertEqual(command("/new build login"), .new(task: "build login", repo: nil))
    }

    func testNewTakesARepoHint() {
        XCTAssertEqual(command("/new @alpha build login"), .new(task: "build login", repo: CommandFixture.alpha))
        XCTAssertEqual(command("/new @ALPHA x"), .new(task: "x", repo: CommandFixture.alpha))
    }

    /// The old grammar silently ignored an unknown repo and started the task
    /// in the first one; a typo is a typo.
    func testNewRejectsUnknownRepo() {
        XCTAssertEqual(error("/new @nope build login"), .unknownRepo("nope"))
        XCTAssertEqual(error("/new @feat-x build login"), .worktreeNotRepo("feat-x"))
    }

    func testNewNeedsATask() {
        XCTAssertEqual(error("/new"), .missingArgument(verb: "new", what: "a task"))
        XCTAssertEqual(error("/new @alpha"), .missingArgument(verb: "new", what: "a task"))
    }

    // MARK: - /go

    func testGoTakesAPaneHandle() {
        XCTAssertEqual(command("/go #7"), .go(.pane(CommandFixture.paneB)))
        XCTAssertEqual(command("/go 7"), .go(.pane(CommandFixture.paneB)))
    }

    func testGoRejectsUnknownOrMalformedPane() {
        XCTAssertEqual(error("/go #8"), .unknownPane(8))
        XCTAssertEqual(error("/go #abc"), .badPaneRef("#abc"))
    }

    func testGoTakesAWorktree() {
        XCTAssertEqual(command("/go @feat-x"), .go(.worktree(CommandFixture.featX)))
        XCTAssertEqual(command("/go feat-x"), .go(.worktree(CommandFixture.featX)))
        XCTAssertEqual(command("/go @FEAT-X"), .go(.worktree(CommandFixture.featX)))
    }

    /// `main` exists in both repos; the reply must say which forms are valid.
    func testAmbiguousBranchNamesBothRepos() {
        XCTAssertEqual(error("/go @main"), .ambiguousWorktree("main", ["alpha/main", "beta/main"]))
        XCTAssertEqual(command("/go @beta/main"), .go(.worktree(CommandFixture.betaMain)))
    }

    func testGoNeedsATarget() {
        XCTAssertEqual(error("/go @nope"), .unknownWorktree("nope"))
        XCTAssertEqual(error("/go"), .missingArgument(verb: "go", what: "a `#pane` or `@worktree`"))
    }

    // MARK: - /show, /order, /broadcast

    func testShowDefaultsToTheBoundPane() {
        XCTAssertEqual(command("/show"), .show(nil))
        XCTAssertEqual(command("/show #12"), .show(CommandFixture.paneC))
    }

    func testOrderNeedsPaneAndText() {
        XCTAssertEqual(command("/order #3 run the tests"), .order(CommandFixture.paneA, "run the tests"))
        XCTAssertEqual(error("/order #3"), .missingArgument(verb: "order", what: "the text to send"))
        XCTAssertEqual(error("/order"), .missingArgument(verb: "order", what: "a `#pane` and the text"))
        XCTAssertEqual(error("/order #9 x"), .unknownPane(9))
    }

    /// `force` is only a flag on the verbs that ask; elsewhere it is a word.
    func testOrderKeepsATrailingForceAsText() {
        XCTAssertEqual(parse("/order #3 use the force"),
                       .success(ParsedLine(.order(CommandFixture.paneA, "use the force"), force: false)))
    }

    func testBroadcast() {
        XCTAssertEqual(command("/broadcast hi all"), .broadcast("hi all"))
        XCTAssertEqual(error("/broadcast"), .missingArgument(verb: "broadcast", what: "the text to send"))
        XCTAssertEqual(parse("/broadcast hi  there force"),
                       .success(ParsedLine(.broadcast("hi  there"), force: true)))
    }

    // MARK: - /status

    func testStatusScopes() {
        XCTAssertEqual(command("/status"), .status(.panes))
        XCTAssertEqual(command("/status worktrees"), .status(.worktrees))
        XCTAssertEqual(command("/status repos"), .status(.repos))
        XCTAssertEqual(error("/status nope"), .badArgument(verb: "status", token: "nope"))
    }

    // MARK: - /return, /forget

    func testBareReturnSweeps() {
        XCTAssertEqual(command("/return"), .returnAll)
    }

    func testReturnNamesAWorktree() {
        XCTAssertEqual(command("/return @feat-x"), .returnWorktree(CommandFixture.featX))
        XCTAssertEqual(parse("/return feat-x force"),
                       .success(ParsedLine(.returnWorktree(CommandFixture.featX), force: true)))
    }

    /// Branch names with `/` are common (`fix/…`, `feat/…`). The row menu builds
    /// `/return @fix/foo` from `label(for:)`; that must resolve to the branch,
    /// not to a fictional repo named `fix`.
    func testReturnResolvesBranchNamesThatContainSlashes() {
        let slashBranch = WorktreeRef(repo: "alpha", branch: "fix/foreign-worktree-path",
                                      path: "/tmp/wt2")
        let index = FleetIndex(panes: [CommandFixture.paneA, CommandFixture.paneB, CommandFixture.paneC],
                               worktrees: [CommandFixture.alphaMain, CommandFixture.featX,
                                           CommandFixture.betaMain, CommandFixture.fixY, slashBranch],
                               repos: [CommandFixture.alpha, CommandFixture.beta])
        let label = index.label(for: slashBranch)
        XCTAssertEqual(label, "@fix/foreign-worktree-path",
                       "a unique slash-branch keeps the short label")
        let parsed = CommandParser.parse("/return \(label)", index: index)
        guard case .success(let line) = parsed,
              case .returnWorktree(let wt) = line.command else {
            return XCTFail("expected return of slash-branch, got \(parsed)")
        }
        XCTAssertEqual(wt.path, slashBranch.path)
    }

    /// When two repos share a slash-branch name, the disambiguated
    /// `@repo/fix/foo` form still has to round-trip (first slash = repo).
    func testReturnResolvesDisambiguatedSlashBranch() {
        let a = WorktreeRef(repo: "alpha", branch: "fix/shared", path: "/a/fix-shared")
        let b = WorktreeRef(repo: "beta", branch: "fix/shared", path: "/b/fix-shared")
        let index = FleetIndex(panes: [], worktrees: [a, b],
                               repos: [CommandFixture.alpha, CommandFixture.beta])
        XCTAssertEqual(index.label(for: a), "@alpha/fix/shared")
        let parsed = CommandParser.parse("/return @alpha/fix/shared", index: index)
        guard case .success(let line) = parsed,
              case .returnWorktree(let wt) = line.command else {
            return XCTFail("expected disambiguated return, got \(parsed)")
        }
        XCTAssertEqual(wt.path, a.path)
    }

    /// The old `/return @repo` overload is gone: a repo name says so.
    func testReturnRefusesARepoAndMain() {
        XCTAssertEqual(error("/return @alpha"), .repoNotWorktree("alpha"))
        XCTAssertEqual(error("/return @beta/main"), .cannotReturnMain("@beta/main"))
        XCTAssertEqual(error("/return @nope"), .unknownWorktree("nope"))
    }

    func testForgetTakesARepo() {
        XCTAssertEqual(command("/forget @alpha"), .forget(CommandFixture.alpha))
        XCTAssertEqual(error("/forget @feat-x"), .worktreeNotRepo("feat-x"))
        XCTAssertEqual(error("/forget"), .missingArgument(verb: "forget", what: "a `@repo`"))
    }

    // MARK: - /integrate

    func testIntegrateModes() {
        XCTAssertEqual(parse("/integrate"), .success(ParsedLine(.integrate(mode: .excludeConflicting))))
        XCTAssertEqual(parse("/integrate full"), .success(ParsedLine(.integrate(mode: .includeWithMarkers))))
        XCTAssertEqual(parse("/integrate FULL force"), .success(ParsedLine(.integrate(mode: .includeWithMarkers), force: true)))
        XCTAssertEqual(parse("/integrate force"), .success(ParsedLine(.integrate(mode: .excludeConflicting), force: true)))
    }

    /// A typo must not quietly drop someone's conflicting work.
    func testIntegrateRejectsAnUnknownArgument() {
        XCTAssertEqual(error("/integrate ful"), .badArgument(verb: "integrate", token: "ful"))
    }

    // MARK: - The rest

    func testSimpleVerbs() {
        XCTAssertEqual(command("/idea dark mode"), .idea("dark mode"))
        XCTAssertEqual(command("/feedback it broke"), .feedback("it broke"))
        XCTAssertEqual(command("/help"), .help(nil))
        XCTAssertEqual(command("/help go"), .help("go"))
        XCTAssertEqual(command("/help /GO"), .help("go"))
        XCTAssertEqual(command("/yes"), .yes)
        XCTAssertEqual(command("/YES"), .yes)
        XCTAssertEqual(command("/add"), .add)
    }

    func testUnknownVerb() {
        XCTAssertEqual(error("/foo bar"), .unknownCommand("foo"))
        XCTAssertEqual(error("/"), .unknownCommand("/"))
    }

    // MARK: - Legacy spellings

    func testOldVerbsStillParseForNow() {
        XCTAssertEqual(command("/worktree"), .status(.worktrees))
        XCTAssertEqual(command("/worktree fix it"), .new(task: "fix it", repo: nil))
        XCTAssertEqual(command("/worktree @feat-x"), .go(.worktree(CommandFixture.featX)))
        XCTAssertEqual(command("/pane"), .status(.panes))
        XCTAssertEqual(command("/panes #7"), .go(.pane(CommandFixture.paneB)))
        XCTAssertEqual(command("/remove @feat-x"), .returnWorktree(CommandFixture.featX))
    }

    // MARK: - Every verb has a spec

    /// The parser and the verb table must agree, or `/help` lists something
    /// that does not parse — or parses something `/help` never mentions.
    func testEverySpecVerbParsesAndEveryParsedVerbHasASpec() {
        for spec in CommandSpecs.all {
            let sample: String
            switch spec.verb {
            case "new": sample = "/new x"
            case "go": sample = "/go #3"
            case "order": sample = "/order #3 x"
            case "broadcast", "idea", "feedback": sample = "/\(spec.verb) x"
            case "forget": sample = "/forget @alpha"
            default: sample = "/\(spec.verb)"
            }
            if case .failure(let e) = parse(sample) {
                XCTFail("`\(sample)` does not parse: \(e)")
            }
        }
        XCTAssertEqual(error("/list"), .unknownCommand("list"))
    }
}
