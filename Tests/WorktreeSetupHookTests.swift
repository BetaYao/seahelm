import XCTest
@testable import seahelm

final class WorktreeSetupHookTests: XCTestCase {
    func testTheNewWorktreesOwnCopyWins() {
        let found = WorktreeSetupHook.script(worktreePath: "/wt", repoPath: "/repo",
                                             exists: { _ in true })
        XCTAssertEqual(found, "/wt/.seahelm/setup.sh")
    }

    /// Kept untracked in the main checkout, it still applies to every worktree.
    func testFallsBackToTheMainCheckout() {
        let found = WorktreeSetupHook.script(worktreePath: "/wt", repoPath: "/repo",
                                             exists: { $0 == "/repo/.seahelm/setup.sh" })
        XCTAssertEqual(found, "/repo/.seahelm/setup.sh")
    }

    func testNoScriptNoSetup() {
        XCTAssertNil(WorktreeSetupHook.script(worktreePath: "/wt", repoPath: "/repo", exists: { _ in false }))
    }

    func testCommandPassesThePathsAndHonoursTheShebang() {
        let executable = WorktreeSetupHook.command(script: "/wt/.seahelm/setup.sh", worktreePath: "/wt",
                                                   repoPath: "/my repo", isExecutable: { _ in true })
        XCTAssertEqual(executable,
                       "SEAHELM_WORKTREE='/wt' SEAHELM_REPO_ROOT='/my repo' '/wt/.seahelm/setup.sh'")
        let plain = WorktreeSetupHook.command(script: "/wt/.seahelm/setup.sh", worktreePath: "/wt",
                                              repoPath: "/repo", isExecutable: { _ in false })
        XCTAssertTrue(plain.hasSuffix(" sh '/wt/.seahelm/setup.sh'"), plain)
    }

    /// A failed setup must not start the agent in a half-built checkout.
    func testTheAgentStartsOnlyAfterASuccessfulSetup() {
        XCTAssertEqual(WorktreeSetupHook.launchLine(setup: "s", agent: "claude"), "s && claude")
        XCTAssertEqual(WorktreeSetupHook.launchLine(setup: "s", agent: nil), "s")
        XCTAssertEqual(WorktreeSetupHook.launchLine(setup: nil, agent: "claude"), "claude")
        XCTAssertNil(WorktreeSetupHook.launchLine(setup: nil, agent: nil))
    }

    /// End to end through a real shell: the script sees both paths and runs in
    /// the new worktree, and its failure stops what follows.
    func testRunsInTheWorktreeWithItsEnvironment() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("setup-hook-\(UUID().uuidString)").path
        let wt = root + "/wt", repo = root + "/repo"
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: wt, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: repo + "/.seahelm", withIntermediateDirectories: true)
        try "echo \"$PWD|$SEAHELM_WORKTREE|$SEAHELM_REPO_ROOT\" > out.txt\n"
            .write(toFile: repo + "/.seahelm/setup.sh", atomically: true, encoding: .utf8)

        let setup = try XCTUnwrap(WorktreeSetupHook.setupCommand(worktreePath: wt, repoPath: repo))
        let line = try XCTUnwrap(WorktreeSetupHook.launchLine(setup: setup, agent: "echo agent > agent.txt"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", line]
        p.currentDirectoryURL = URL(fileURLWithPath: wt)
        try p.run(); p.waitUntilExit()

        let out = try String(contentsOfFile: wt + "/out.txt", encoding: .utf8)
        let real = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|").map(String.init)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(real(parts[0]), real(wt))
        XCTAssertEqual(parts[1], wt)
        XCTAssertEqual(parts[2], repo)
        XCTAssertTrue(fm.fileExists(atPath: wt + "/agent.txt"))

        try "exit 3\n".write(toFile: repo + "/.seahelm/setup.sh", atomically: true, encoding: .utf8)
        try fm.removeItem(atPath: wt + "/agent.txt")
        let q = Process()
        q.executableURL = URL(fileURLWithPath: "/bin/sh")
        q.arguments = ["-c", line]
        q.currentDirectoryURL = URL(fileURLWithPath: wt)
        try q.run(); q.waitUntilExit()
        XCTAssertFalse(fm.fileExists(atPath: wt + "/agent.txt"), "the agent started after a failed setup")
    }
}
