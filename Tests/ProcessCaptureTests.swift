import XCTest
@testable import seahelm

/// Regression tests for the subprocess plumbing behind `ProcessRunner.capture`
/// and its git-specific wrapper `GitProcess`.
///
/// The bug these exist to prevent: reading a child's pipe only after
/// `waitUntilExit()` deadlocks once output exceeds the pipe buffer. It is not a
/// slow path or a flaky path — it hangs forever, and every wedged call leaks a
/// thread plus two pipes. So the important assertions here are the large-output
/// ones, and they must be written so a regression *fails* rather than hanging
/// the whole test run: every call goes through `runBounded`, which fails the
/// test if the work does not finish in time.
final class ProcessCaptureTests: XCTestCase {

    /// Comfortably past any pipe buffer (macOS hands out 16KB, shrinking to 4KB
    /// under pipe-KVA pressure — which is exactly the state a leak produces).
    private let bigLineCount = 200_000

    // MARK: - Helpers

    /// Runs `work` off-thread and fails instead of hanging if it overruns.
    /// Without this, a regression in the drain logic would wedge the suite.
    private func runBounded<T>(
        timeout: TimeInterval = 60,
        _ work: @escaping () -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> T? {
        let done = expectation(description: "subprocess finished")
        var result: T?
        DispatchQueue.global(qos: .userInitiated).async {
            result = work()
            done.fulfill()
        }
        let outcome = XCTWaiter().wait(for: [done], timeout: timeout)
        if outcome != .completed {
            XCTFail("subprocess did not finish within \(timeout)s — likely a pipe deadlock", file: file, line: line)
            return nil
        }
        return result
    }

    private func bash(_ script: String, timeout: TimeInterval? = 60) -> ProcessRunner.Capture? {
        runBounded {
            ProcessRunner.capture(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-c", script],
                timeout: timeout
            )
        }
    }

    // MARK: - The deadlock

    func testStdoutLargerThanPipeBufferDoesNotDeadlock() {
        let result = bash("seq 1 \(bigLineCount)")
        XCTAssertEqual(result?.exitCode, 0)
        XCTAssertEqual(result?.timedOut, false)
        // Every line must survive — a partial read would mean we stopped
        // draining early and merely got lucky on the exit.
        XCTAssertEqual(result?.stdout.split(separator: "\n").count, bigLineCount)
        XCTAssertGreaterThan(result?.stdout.utf8.count ?? 0, 1_000_000)
    }

    func testStderrLargerThanPipeBufferDoesNotDeadlock() {
        // stderr is the easier one to forget: several helpers piped it and then
        // never read it, which wedges the child just as thoroughly as stdout.
        let result = bash("seq 1 \(bigLineCount) >&2")
        XCTAssertEqual(result?.exitCode, 0)
        XCTAssertEqual(result?.stderr.split(separator: "\n").count, bigLineCount)
        XCTAssertEqual(result?.stdout, "")
    }

    func testBothStreamsLargeSimultaneously() {
        // Interleaved writers: whichever stream we neglect fills first and stops
        // the child, so this fails if the two drains are not concurrent.
        let result = bash("seq 1 \(bigLineCount) & seq 1 \(bigLineCount) >&2; wait")
        XCTAssertEqual(result?.exitCode, 0)
        XCTAssertEqual(result?.stdout.split(separator: "\n").count, bigLineCount)
        XCTAssertEqual(result?.stderr.split(separator: "\n").count, bigLineCount)
    }

    // MARK: - Exit status

    func testNonZeroExitIsReported() {
        let result = bash("echo out; echo err >&2; exit 3")
        XCTAssertEqual(result?.exitCode, 3)
        XCTAssertEqual(result?.succeeded, false)
        XCTAssertEqual(result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out")
        XCTAssertEqual(result?.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "err")
    }

    func testEmptyOutputStillSucceeds() {
        // Distinct from failure: a clean exit with nothing to say. `git status`
        // on a clean tree hits this, and conflating it with nil would make a
        // clean worktree look like an error.
        let result = bash("true")
        XCTAssertEqual(result?.succeeded, true)
        XCTAssertEqual(result?.stdout, "")
    }

    func testLaunchFailureIsReportedNotCrashed() {
        let result = runBounded {
            ProcessRunner.capture(
                executable: URL(fileURLWithPath: "/nonexistent/binary"),
                arguments: [],
                timeout: 5
            )
        }
        XCTAssertNil(result?.exitCode)
        XCTAssertEqual(result?.succeeded, false)
        XCTAssertEqual(result?.timedOut, false)
    }

    // MARK: - Deadline

    func testTimeoutTerminatesAndReports() {
        let started = Date()
        let result = bash("sleep 30", timeout: 2)
        XCTAssertEqual(result?.timedOut, true)
        XCTAssertNil(result?.exitCode)
        // The deadline must actually bound the wait, not just label the result.
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    func testTimeoutDoesNotFireForWorkThatFinishes() {
        let result = bash("echo quick", timeout: 30)
        XCTAssertEqual(result?.timedOut, false)
        XCTAssertEqual(result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "quick")
    }

    // MARK: - stdin

    func testStandardInputIsDelivered() {
        let result = runBounded {
            ProcessRunner.capture(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-c", "cat"],
                standardInput: "hello from stdin",
                timeout: 30
            )
        }
        XCTAssertEqual(result?.succeeded, true)
        XCTAssertEqual(result?.stdout, "hello from stdin")
    }

    func testStandardInputToAChildThatNeverReadsItDoesNotHang() {
        // `git credential fill` can exit without draining stdin; writing inline
        // would block us mid-write, so the write has to be off-thread.
        let result = runBounded {
            ProcessRunner.capture(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-c", "echo ignored-stdin"],
                standardInput: String(repeating: "x", count: 1_000_000),
                timeout: 30
            )
        }
        XCTAssertEqual(result?.succeeded, true)
        XCTAssertEqual(result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "ignored-stdin")
    }

    // MARK: - Concurrency

    func testConcurrentCapturesAllComplete() {
        // The failure mode was contagious: wedged callers starved the dispatch
        // pool until unrelated subprocesses reported spurious timeouts.
        let count = 12
        let done = expectation(description: "all captures finished")
        done.expectedFulfillmentCount = count
        var results = [ProcessRunner.Capture?](repeating: nil, count: count)
        let lock = NSLock()
        for i in 0..<count {
            DispatchQueue.global(qos: .userInitiated).async {
                let r = ProcessRunner.capture(
                    executable: URL(fileURLWithPath: "/bin/bash"),
                    arguments: ["-c", "seq 1 20000"],
                    timeout: 60
                )
                lock.lock(); results[i] = r; lock.unlock()
                done.fulfill()
            }
        }
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 90), .completed)
        for r in results {
            XCTAssertEqual(r?.exitCode, 0)
            XCTAssertEqual(r?.stdout.split(separator: "\n").count, 20000)
        }
    }

    // MARK: - Descriptor leaks

    /// Open descriptors in this process. Cheap enough to call per assertion.
    private func openDescriptorCount() -> Int {
        (0..<8192).reduce(0) { fcntl(Int32($1), F_GETFD) != -1 ? $0 + 1 : $0 }
    }

    /// Reaching EOF does not release a pipe's read end, and `Process` keeps its
    /// pipes alive past the call, so every capture used to strand two
    /// descriptors. That leak is the reason the original deadlock was
    /// reachable at all: enough stranded pipes exhaust the machine-wide pipe
    /// budget, the kernel starts handing out minimal buffers, and a write of
    /// only a few KB begins to block. Guard every path, not just the happy one.
    private func assertNoDescriptorLeak(
        iterations: Int = 25,
        _ body: () -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Warm up first: the initial calls spin up queue threads and other
        // one-time state, which would otherwise read as a leak.
        for _ in 0..<3 { body() }
        let before = openDescriptorCount()
        for _ in 0..<iterations { body() }
        let after = openDescriptorCount()
        XCTAssertEqual(
            after, before,
            "leaked \(after - before) descriptors over \(iterations) calls",
            file: file, line: line
        )
    }

    func testNoDescriptorLeakOnNormalRun() {
        assertNoDescriptorLeak { _ = self.bash("echo hi") }
    }

    func testNoDescriptorLeakOnLargeOutput() {
        assertNoDescriptorLeak(iterations: 10) { _ = self.bash("seq 1 100000") }
    }

    func testNoDescriptorLeakOnTimeout() {
        assertNoDescriptorLeak(iterations: 5) { _ = self.bash("sleep 30", timeout: 1) }
    }

    func testNoDescriptorLeakOnLaunchFailure() {
        // The early-return path: nothing spawned, so no drain thread exists to
        // close the pipes it never got to read.
        assertNoDescriptorLeak {
            _ = self.runBounded {
                ProcessRunner.capture(
                    executable: URL(fileURLWithPath: "/nonexistent/binary"),
                    arguments: [],
                    timeout: 5
                )
            }
        }
    }

    func testNoDescriptorLeakWithStandardInput() {
        assertNoDescriptorLeak {
            _ = self.runBounded {
                ProcessRunner.capture(
                    executable: URL(fileURLWithPath: "/bin/bash"),
                    arguments: ["-c", "cat"],
                    standardInput: "payload",
                    timeout: 20
                )
            }
        }
    }

    // MARK: - GitProcess wrapper

    private var repoDir: URL!

    override func tearDown() {
        if let repoDir { try? FileManager.default.removeItem(at: repoDir) }
        repoDir = nil
        super.tearDown()
    }

    /// Temp repo whose single tracked file is large enough that any diff against
    /// it blows past the pipe buffer — the shape of the real failure.
    private func makeRepoWithLargeDiff() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-gitprocess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        repoDir = dir

        let file = dir.appendingPathComponent("big.txt")
        try (1...20_000).map { "original line \($0)" }.joined(separator: "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        for args in [
            ["init", "--quiet"],
            ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Test"],
            ["add", "big.txt"],
            ["commit", "--quiet", "-m", "seed"],
        ] {
            let r = GitProcess.capture(args, in: dir.path, timeout: 30)
            XCTAssertTrue(r.succeeded, "git \(args.joined(separator: " ")) failed: \(r.stderr)")
        }

        // Rewrite every line so the diff is ~20k additions + 20k deletions.
        try (1...20_000).map { "rewritten line \($0)" }.joined(separator: "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        return dir
    }

    func testGitProcessHandlesDiffLargerThanPipeBuffer() throws {
        let dir = try makeRepoWithLargeDiff()
        let output = runBounded {
            GitProcess.run(["diff", "--no-color"], in: dir.path, timeout: 30)
        }
        guard let diff = output ?? nil else {
            XCTFail("git diff returned nil")
            return
        }
        XCTAssertGreaterThan(diff.utf8.count, 500_000)
        XCTAssertEqual(diff.split(separator: "\n").filter { $0.hasPrefix("+rewritten") }.count, 20_000)
        XCTAssertEqual(diff.split(separator: "\n").filter { $0.hasPrefix("-original") }.count, 20_000)
    }

    func testGitProcessRunReturnsNilOnNonZeroExit() throws {
        let dir = try makeRepoWithLargeDiff()
        let output = runBounded {
            GitProcess.run(["rev-parse", "--verify", "--quiet", "refs/heads/no-such-branch"], in: dir.path, timeout: 30)
        }
        XCTAssertNil(output ?? nil)
    }

    func testGitProcessCaptureSurfacesStderrOnFailure() throws {
        let dir = try makeRepoWithLargeDiff()
        let result = runBounded {
            GitProcess.capture(["checkout", "definitely-not-a-ref"], in: dir.path, timeout: 30)
        }
        XCTAssertEqual(result?.succeeded, false)
        XCTAssertFalse((result?.stderr ?? "").isEmpty, "git's own error text should reach the caller")
    }

    func testGitProcessCleanTreeYieldsEmptyStringNotNil() throws {
        let dir = try makeRepoWithLargeDiff()
        // Restore the file so the tree is clean again.
        _ = runBounded { GitProcess.run(["checkout", "--", "big.txt"], in: dir.path, timeout: 30) }
        let output = runBounded {
            GitProcess.run(["status", "--porcelain=v1"], in: dir.path, timeout: 30)
        }
        XCTAssertEqual(output ?? nil, "", "a clean tree is success-with-no-output, not failure")
    }
}
