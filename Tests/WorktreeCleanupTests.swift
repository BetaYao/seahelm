import XCTest
@testable import seahelm

final class WorktreeCleanupPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var twoDaysAgo: Date { now.addingTimeInterval(-2 * 86_400) }
    private var anHourAgo: Date { now.addingTimeInterval(-3600) }

    private var settled: WorktreeCleanupProbe {
        WorktreeCleanupProbe(headCommittedAt: twoDaysAgo, createdAt: twoDaysAgo, outstandingFiles: 0)
    }

    private func candidate(isMain: Bool = false, isIntegration: Bool = false,
                           statuses: [AgentStatus] = [.idle], lastActivity: Date? = nil,
                           probe: WorktreeCleanupProbe?) -> Bool {
        WorktreeCleanupPolicy.isCandidate(isMain: isMain, isIntegration: isIntegration,
                                          statuses: statuses, lastActivity: lastActivity ?? twoDaysAgo,
                                          probe: probe, now: now)
    }

    func testAWorktreeQuietForADayWithNothingToPRIsACandidate() {
        XCTAssertTrue(candidate(probe: settled))
    }

    func testMainAndTheIntegrationCheckoutNeverAre() {
        XCTAssertFalse(candidate(isMain: true, probe: settled))
        XCTAssertFalse(candidate(isIntegration: true, probe: settled))
        XCTAssertFalse(WorktreeCleanupPolicy.isQuiet(isMain: true, isIntegration: false, statuses: [.idle],
                                                     lastActivity: twoDaysAgo, now: now),
                       "main must not even cost a probe")
    }

    /// A long build prints nothing and advances no activity clock; an agent
    /// waiting on a question is not finished.
    func testARunningOrWaitingPaneIsNotQuiet() {
        XCTAssertFalse(candidate(statuses: [.idle, .running], probe: settled))
        XCTAssertFalse(candidate(statuses: [.waiting], probe: settled))
        XCTAssertTrue(candidate(statuses: [.error, .exited, .unknown], probe: settled))
    }

    func testAnyMovementWithinTheDayKeepsItOff() {
        XCTAssertFalse(candidate(lastActivity: anHourAgo, probe: settled))
        var committed = settled
        committed.headCommittedAt = anHourAgo
        XCTAssertFalse(candidate(probe: committed))
        var created = settled
        created.createdAt = anHourAgo
        XCTAssertFalse(candidate(probe: created), "a fresh checkout of an old commit")
    }

    func testTheBoundaryIsInclusive() {
        let exactly = now.addingTimeInterval(-WorktreeCleanupPolicy.quietInterval)
        XCTAssertTrue(candidate(lastActivity: exactly, probe: settled))
        XCTAssertFalse(candidate(lastActivity: exactly.addingTimeInterval(1), probe: settled))
    }

    /// Outstanding work, or no way to know, is not "nothing to PR".
    func testOutstandingOrUnknownWorkKeepsItOff() {
        var outstanding = settled
        outstanding.outstandingFiles = 1
        XCTAssertFalse(candidate(probe: outstanding))
        var unknown = settled
        unknown.outstandingFiles = nil
        XCTAssertFalse(candidate(probe: unknown))
        XCTAssertFalse(candidate(probe: nil), "not probed yet")
    }

    func testAnUnknownDateIsNoEvidenceOfMovement() {
        XCTAssertTrue(candidate(probe: WorktreeCleanupProbe(headCommittedAt: twoDaysAgo, createdAt: nil,
                                                            outstandingFiles: 0)))
        XCTAssertTrue(WorktreeCleanupPolicy.isQuiet(isMain: false, isIntegration: false, statuses: [.idle],
                                                    lastActivity: nil, now: now))
    }
}

final class WorktreeCleanupStoreTests: XCTestCase {
    func testRefreshResolvesOnceAndReportsOnlyAChange() {
        let resolved = expectation(description: "first resolve reported")
        var calls = 0
        var answer = WorktreeCleanupProbe(outstandingFiles: 0)
        let store = WorktreeCleanupStore(resolve: { _ in calls += 1; return answer })
        store.onChange = { path in
            XCTAssertEqual(path, "/w")
            resolved.fulfill()
        }

        let start = Date()
        store.refresh(worktreePath: "/w", now: start)
        store.refresh(worktreePath: "/w", now: start) // in flight — no second resolve
        wait(for: [resolved], timeout: 2)
        XCTAssertEqual(store.probe(worktreePath: "/w"), answer)

        store.refresh(worktreePath: "/w", now: Date()) // fresh — served from cache
        // Past the TTL with the same answer: resolves again, reports nothing.
        store.onChange = { _ in XCTFail("an unchanged probe repainted the fleet") }
        let later = Date().addingTimeInterval(WorktreeCleanupStore.ttl + 1)
        store.refresh(worktreePath: "/w", now: later)
        drainMainQueue()
        XCTAssertEqual(calls, 2)

        let changed = expectation(description: "changed probe reported")
        answer.outstandingFiles = 3
        store.onChange = { _ in changed.fulfill() }
        store.refresh(worktreePath: "/w", now: later.addingTimeInterval(WorktreeCleanupStore.ttl + 1))
        wait(for: [changed], timeout: 2)
        XCTAssertEqual(store.probe(worktreePath: "/w")?.outstandingFiles, 3)

        store.evict(worktreePath: "/w")
        XCTAssertNil(store.probe(worktreePath: "/w"))
    }

    /// Lets the store's serial queue finish, then the main-queue hop after it.
    private func drainMainQueue() {
        let done = expectation(description: "drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            DispatchQueue.main.async { done.fulfill() }
        }
        wait(for: [done], timeout: 2)
    }
}

final class WorktreeCleanupProbeTests: XCTestCase {
    private var tempDir: URL!

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    /// A branch whose work main already has reads as nothing to PR; one more
    /// commit on it does not.
    func testCountsWhatTheBranchStillOwesItsBase() throws {
        let worktree = try makeMergedWorktree()
        // Everything on disk was made seconds ago; judge it from two days on.
        let later = Date().addingTimeInterval(2 * 86_400)

        let merged = WorktreeCleanupProbe.resolve(worktreePath: worktree, now: later)
        XCTAssertNotNil(merged.headCommittedAt)
        XCTAssertNotNil(merged.createdAt)
        XCTAssertEqual(merged.outstandingFiles, 0)

        try "more\n".write(toFile: worktree + "/more.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(WorktreeCleanupProbe.resolve(worktreePath: worktree, now: later).outstandingFiles, 1,
                       "an untracked file is work")
        commitAll(in: worktree, message: "more")
        XCTAssertEqual(WorktreeCleanupProbe.resolve(worktreePath: worktree, now: later).outstandingFiles, 1)
    }

    /// Moved within the day: the expensive count is skipped, not reported as zero.
    func testSkipsTheCountForAWorktreeThatJustMoved() throws {
        let worktree = try makeMergedWorktree()
        let probe = WorktreeCleanupProbe.resolve(worktreePath: worktree, now: Date())
        XCTAssertNotNil(probe.headCommittedAt)
        XCTAssertNil(probe.outstandingFiles)
    }

    // MARK: - helpers

    /// `repo` on main, and a `feat` worktree beside it whose one commit main
    /// has since merged.
    private func makeMergedWorktree() throws -> String {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let repo = tempDir.appendingPathComponent("repo").path
        let worktree = tempDir.appendingPathComponent("feat").path
        runGit(["init", "-q", "-b", "main", repo], in: tempDir.path)
        try "base\n".write(toFile: repo + "/base.txt", atomically: true, encoding: .utf8)
        commitAll(in: repo, message: "init")
        runGit(["worktree", "add", "-q", "-b", "feat", worktree], in: repo)
        try "feature\n".write(toFile: worktree + "/feature.txt", atomically: true, encoding: .utf8)
        commitAll(in: worktree, message: "feat")
        runGit(["merge", "-q", "--ff-only", "feat"], in: repo)
        return worktree
    }

    private func commitAll(in repo: String, message: String) {
        runGit(["add", "-A"], in: repo)
        runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", message], in: repo)
    }

    private func runGit(_ args: [String], in directory: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        try? process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
}
