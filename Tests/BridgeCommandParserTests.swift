import XCTest
@testable import seahelm

final class BridgeCommandParserTests: XCTestCase {
    let wts = [
        WorktreeRef(branch: "feat-x", path: "/repo/feat-x"),
        WorktreeRef(branch: "fix-y", path: "/repo/fix-y"),
    ]

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
}
