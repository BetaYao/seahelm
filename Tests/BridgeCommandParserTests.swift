import XCTest
@testable import seahelm

final class BridgeCommandParserTests: XCTestCase {
    let wts = [
        WorktreeRef(branch: "feat-x", path: "/repo/feat-x"),
        WorktreeRef(branch: "fix-y", path: "/repo/fix-y"),
    ]
    let repos = ["/workspaces/alpha", "/workspaces/beta"]

    func testNoPrefixIsNewWorktree() {
        XCTAssertEqual(BridgeCommandParser.parse("add dark mode", worktrees: wts),
                       .success(.newWorktree(task: "add dark mode")))
    }

    func testEmptyIsError() {
        XCTAssertEqual(BridgeCommandParser.parse("   ", worktrees: wts), .failure(.emptyTask))
    }

    func testNewExplicit() {
        XCTAssertEqual(BridgeCommandParser.parse("/new build login", worktrees: wts),
                       .success(.newWorktree(task: "build login")))
    }

    func testNewWithAtRepoExtractsHint() {
        XCTAssertEqual(BridgeCommandParser.parse("/new @alpha build login", worktrees: wts, repoPaths: repos),
                       .success(.newWorktree(task: "build login", repoHint: "/workspaces/alpha")))
    }

    func testNewAtRepoAtEnd() {
        // @repo can also appear as the first token of free text
        XCTAssertEqual(BridgeCommandParser.parse("@beta fix auth", worktrees: wts, repoPaths: repos),
                       .success(.newWorktree(task: "fix auth", repoHint: "/workspaces/beta")))
    }

    func testNewAtRepoUnknownIgnored() {
        // Unknown @name → no hint, @name stays in task text (treat as plain text)
        let result = BridgeCommandParser.parse("/new @unknown task", worktrees: wts, repoPaths: repos)
        XCTAssertEqual(result, .success(.newWorktree(task: "task", repoHint: nil)))
    }

    func testNewAtRepoCaseInsensitive() {
        XCTAssertEqual(BridgeCommandParser.parse("/new @ALPHA do work", worktrees: wts, repoPaths: repos),
                       .success(.newWorktree(task: "do work", repoHint: "/workspaces/alpha")))
    }

    func testOrderResolvesBranch() {
        XCTAssertEqual(BridgeCommandParser.parse("/order feat-x keep going", worktrees: wts),
                       .success(.orderExisting(worktreePath: "/repo/feat-x", task: "keep going")))
    }

    func testOrderUnknownBranch() {
        XCTAssertEqual(BridgeCommandParser.parse("/order nope do it", worktrees: wts),
                       .failure(.unknownBranch("nope")))
    }

    func testOrderMissingTask() {
        XCTAssertEqual(BridgeCommandParser.parse("/order feat-x", worktrees: wts), .failure(.emptyTask))
    }

    func testReturnResolvesBranch() {
        XCTAssertEqual(BridgeCommandParser.parse("/return fix-y", worktrees: wts),
                       .success(.returnToPort(worktreePath: "/repo/fix-y")))
    }

    func testReturnNoArgIsReturnAll() {
        XCTAssertEqual(BridgeCommandParser.parse("/return", worktrees: wts), .success(.returnAll))
    }

    func testCommitResolvesBranch() {
        XCTAssertEqual(BridgeCommandParser.parse("/commit feat-x", worktrees: wts),
                       .success(.commit(worktreePath: "/repo/feat-x")))
    }

    func testBroadcast() {
        XCTAssertEqual(BridgeCommandParser.parse("/broadcast run tests", worktrees: wts),
                       .success(.broadcast(task: "run tests")))
    }

    func testUnknownCommand() {
        XCTAssertEqual(BridgeCommandParser.parse("/frobnicate x", worktrees: wts),
                       .failure(.unknownCommand("frobnicate")))
    }

    // MARK: - /remove: repo name drops the repo, branch name deletes the worktree

    func testRemoveRepoNameDropsRepo() {
        XCTAssertEqual(BridgeCommandParser.parse("/remove @beta", worktrees: wts, repoPaths: repos),
                       .success(.removeRepo(repoPath: "/workspaces/beta")))
    }

    func testRemoveBranchNameDeletesWorktree() {
        XCTAssertEqual(BridgeCommandParser.parse("/remove @feat-x", worktrees: wts, repoPaths: repos),
                       .success(.removeWorktree(worktreePath: "/repo/feat-x")))
    }

    /// `@` is how /new spells a repo, but a bare name is the obvious thing to type.
    func testRemoveAcceptsBareName() {
        XCTAssertEqual(BridgeCommandParser.parse("/remove alpha", worktrees: wts, repoPaths: repos),
                       .success(.removeRepo(repoPath: "/workspaces/alpha")))
        XCTAssertEqual(BridgeCommandParser.parse("/remove fix-y", worktrees: wts, repoPaths: repos),
                       .success(.removeWorktree(worktreePath: "/repo/fix-y")))
    }

    func testRemoveIsCaseInsensitive() {
        XCTAssertEqual(BridgeCommandParser.parse("/remove @BETA", worktrees: wts, repoPaths: repos),
                       .success(.removeRepo(repoPath: "/workspaces/beta")))
        XCTAssertEqual(BridgeCommandParser.parse("/remove @FEAT-X", worktrees: wts, repoPaths: repos),
                       .success(.removeWorktree(worktreePath: "/repo/feat-x")))
    }

    /// A repo name wins a collision: dropping a repo leaves worktrees on disk,
    /// so it is the recoverable branch of the two.
    func testRemovePrefersRepoOnNameCollision() {
        let clash = [WorktreeRef(branch: "alpha", path: "/repo/alpha")]
        XCTAssertEqual(BridgeCommandParser.parse("/remove alpha", worktrees: clash, repoPaths: repos),
                       .success(.removeRepo(repoPath: "/workspaces/alpha")))
    }

    /// Must not fall through to some other target — either verb is destructive.
    func testRemoveUnknownTargetFails() {
        XCTAssertEqual(BridgeCommandParser.parse("/remove @nope", worktrees: wts, repoPaths: repos),
                       .failure(.unknownTarget("nope")))
    }

    func testRemoveWithoutArgumentFails() {
        XCTAssertEqual(BridgeCommandParser.parse("/remove", worktrees: wts, repoPaths: repos),
                       .failure(.missingArgument("remove")))
    }

    /// A repo name that resolves must name a real tab: the parser matches on the
    /// directory name, which is what WorkspaceTab.displayName derives from.
    func testRemoveMatchesOnDirectoryName() {
        let nested = ["/a/b/c/myrepo"]
        XCTAssertEqual(BridgeCommandParser.parse("/remove @myrepo", worktrees: wts, repoPaths: nested),
                       .success(.removeRepo(repoPath: "/a/b/c/myrepo")))
    }
}
