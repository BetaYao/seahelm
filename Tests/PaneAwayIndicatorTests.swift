import XCTest
@testable import seahelm

final class PaneAwayIndicatorTests: XCTestCase {

    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let shorten: (String) -> String = { path in
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    func testNoSuffixWhenHookSaysSameWorktree() {
        XCTAssertNil(PaneAwayIndicator.titleSuffix(
            filedWorktree: "/repo",
            hookWorktree: "/repo",
            hookCwd: "/repo/Sources",
            hasHookLocation: true,
            pwd: "/elsewhere",
            shorten: shorten))
    }

    func testSuffixWhenHookSaysOtherWorktree() {
        XCTAssertEqual(
            PaneAwayIndicator.titleSuffix(
                filedWorktree: "/repo",
                hookWorktree: "/repo-worktrees/feature",
                hookCwd: "/repo-worktrees/feature",
                hasHookLocation: true,
                pwd: "",
                shorten: shorten),
            " · /repo-worktrees/feature")
    }

    func testSuffixWhenHookCwdMatchesNoWorktree() {
        XCTAssertEqual(
            PaneAwayIndicator.titleSuffix(
                filedWorktree: "/repo",
                hookWorktree: nil,
                hookCwd: "/tmp/scratch",
                hasHookLocation: true,
                pwd: "",
                shorten: shorten),
            " · /tmp/scratch")
    }

    func testPwdFallbackWhenNoHook() {
        XCTAssertEqual(
            PaneAwayIndicator.titleSuffix(
                filedWorktree: "/repo",
                hookWorktree: nil,
                hookCwd: nil,
                hasHookLocation: false,
                pwd: "/tmp/scratch",
                shorten: shorten),
            " · /tmp/scratch")
    }

    func testNoSuffixWhenPwdIsInsideFiledWorktree() {
        XCTAssertNil(PaneAwayIndicator.titleSuffix(
            filedWorktree: "/repo",
            hookWorktree: nil,
            hookCwd: nil,
            hasHookLocation: false,
            pwd: "/repo/Sources/Core",
            shorten: shorten))
    }

    func testShortensHomeInSuffix() {
        let cwd = home + "/code/other"
        XCTAssertEqual(
            PaneAwayIndicator.titleSuffix(
                filedWorktree: home + "/code/seahelm",
                hookWorktree: nil,
                hookCwd: nil,
                hasHookLocation: false,
                pwd: cwd,
                shorten: shorten),
            " · ~/code/other")
    }
}
