import XCTest
@testable import seahelm

/// Where a split opens (issue #27).
final class PaneWorkingDirectoryTests: XCTestCase {
    private let all: (String) -> Bool = { _ in true }

    /// The kernel outranks OSC 7, which outranks where the pane was created —
    /// and the worktree root is the floor, not the answer.
    func testTheLadderPrefersTheFreshestSource() {
        XCTAssertEqual(
            PaneWorkingDirectory.choose(probed: "/probed", oscPwd: "/osc", initial: "/initial",
                                        worktreePath: "/wt", exists: all),
            "/probed")
        XCTAssertEqual(
            PaneWorkingDirectory.choose(probed: nil, oscPwd: "/osc", initial: "/initial",
                                        worktreePath: "/wt", exists: all),
            "/osc")
        XCTAssertEqual(
            PaneWorkingDirectory.choose(probed: nil, oscPwd: nil, initial: "/initial",
                                        worktreePath: "/wt", exists: all),
            "/initial")
    }

    /// A pane that says nothing about itself behaves exactly as it did before
    /// this existed: the split opens at the worktree root.
    func testTheWorktreeRootIsTheFloor() {
        XCTAssertEqual(
            PaneWorkingDirectory.choose(probed: nil, oscPwd: "", initial: "   ",
                                        worktreePath: "/wt", exists: all),
            "/wt")
    }

    /// A directory that has been deleted under the pane must not be handed to
    /// surface creation — it takes the next candidate down instead.
    func testAVanishedDirectoryIsSkipped() {
        XCTAssertEqual(
            PaneWorkingDirectory.choose(probed: "/gone", oscPwd: "/still-here", initial: nil,
                                        worktreePath: "/wt", exists: { $0 != "/gone" }),
            "/still-here")
        XCTAssertEqual(
            PaneWorkingDirectory.choose(probed: "/gone", oscPwd: "/also-gone", initial: "/gone-too",
                                        worktreePath: "/wt", exists: { _ in false }),
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
}
