import XCTest
@testable import seahelm

/// Where a split opens (issue #27).
final class PaneWorkingDirectoryTests: XCTestCase {
    private let all: (String) -> Bool = { _ in true }

    /// The kernel outranks OSC 7, which outranks where the pane was created —
    /// and the worktree root is the floor, not the answer.
    func testTheLadderPrefersTheFreshestSource() {
        XCTAssertEqual(
            PaneWorkingDirectory.choose(probed: "/wt/probed", oscPwd: "/wt/osc", initial: "/wt/initial",
                                        worktreePath: "/wt", exists: all, canonical: { $0 }),
            "/wt/probed")
        XCTAssertEqual(
            PaneWorkingDirectory.choose(probed: nil, oscPwd: "/wt/osc", initial: "/wt/initial",
                                        worktreePath: "/wt", exists: all, canonical: { $0 }),
            "/wt/osc")
        XCTAssertEqual(
            PaneWorkingDirectory.choose(probed: nil, oscPwd: nil, initial: "/wt/initial",
                                        worktreePath: "/wt", exists: all, canonical: { $0 }),
            "/wt/initial")
    }

    /// A pane that says nothing about itself behaves exactly as it did before
    /// this existed: the split opens at the worktree root.
    func testTheWorktreeRootIsTheFloor() {
        XCTAssertEqual(
            PaneWorkingDirectory.choose(probed: nil, oscPwd: "", initial: "   ",
                                        worktreePath: "/wt", exists: all, canonical: { $0 }),
            "/wt")
    }

    /// A directory that has been deleted under the pane must not be handed to
    /// surface creation — it takes the next candidate down instead.
    func testAVanishedDirectoryIsSkipped() {
        XCTAssertEqual(
            PaneWorkingDirectory.choose(probed: "/wt/gone", oscPwd: "/wt/still-here", initial: nil,
                                        worktreePath: "/wt", exists: { $0 != "/wt/gone" }, canonical: { $0 }),
            "/wt/still-here")
        XCTAssertEqual(
            PaneWorkingDirectory.choose(probed: "/wt/gone", oscPwd: "/wt/also-gone", initial: "/wt/gone-too",
                                        worktreePath: "/wt", exists: { _ in false }, canonical: { $0 }),
            "/wt")
    }

    /// The kernel read itself — the part the ladder cannot fake. Asked of this
    /// process, whose directory the test already knows.
    func testTheCwdOfALiveProcessIsReadable() throws {
        let mine = try XCTUnwrap(PaneWorkingDirectory.cwd(ofPid: getpid()))
        XCTAssertEqual(URL(fileURLWithPath: mine).resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                           .resolvingSymlinksInPath().path)
    }

    func testADeadProcessSaysNothing() {
        // pid 0 is the kernel's own — never a shell, and never readable as one.
        XCTAssertNil(PaneWorkingDirectory.cwd(ofPid: -1))
    }

    func testAPaneWithNoSessionIsNotProbed() {
        XCTAssertNil(PaneWorkingDirectory.probeSessionCwd(paneSessionKey: ""))
    }

    /// A pane moved to another worktree keeps its process, and so its old cwd.
    /// A split must open in the worktree the pane is filed under, not back in
    /// the one it left.
    func testADirectoryOutsideTheWorktreeIsNotInherited() {
        XCTAssertEqual(
            PaneWorkingDirectory.choose(probed: "/old-wt/src", oscPwd: "/old-wt", initial: "/old-wt",
                                        worktreePath: "/wt", exists: { _ in true }, canonical: { $0 }),
            "/wt")
        XCTAssertEqual(
            PaneWorkingDirectory.choose(probed: "/old-wt", oscPwd: "/wt/sub", initial: nil,
                                        worktreePath: "/wt", exists: { _ in true }, canonical: { $0 }),
            "/wt/sub")
        // A sibling whose name only starts with the worktree's is outside it.
        XCTAssertEqual(
            PaneWorkingDirectory.choose(probed: "/wt-other", oscPwd: nil, initial: nil,
                                        worktreePath: "/wt", exists: { _ in true }, canonical: { $0 }),
            "/wt")
    }
}
