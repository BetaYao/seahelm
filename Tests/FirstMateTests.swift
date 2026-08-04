import XCTest
@testable import seahelm

final class FirstMateTests: XCTestCase {
    private func tx(_ old: SailorStatus, _ new: SailorStatus,
                    hold: Double = 0, completion: Bool = false) -> StatusTransition {
        StatusTransition(worktreePath: "/wt/x", branch: "feat-x", project: "repo",
                         terminalID: "t1", oldStatus: old, newStatus: new,
                         holdSeconds: hold, isCompletionSignal: completion)
    }

    func testWaitingBeyondTimeoutEmitsGreenWatch() {
        let acts = FirstMate.evaluate(tx(.running, .waiting, hold: 31), config: .default)
        XCTAssertEqual(acts.map(\.kind), [.watchWaiting])
        XCTAssertEqual(acts.first?.zone, .green)
    }

    func testWaitingUnderTimeoutEmitsNothing() {
        let acts = FirstMate.evaluate(tx(.running, .waiting, hold: 5), config: .default)
        XCTAssertTrue(acts.isEmpty)
    }

    func testErrorEmitsGreenWatchError() {
        let acts = FirstMate.evaluate(tx(.running, .error), config: .default)
        XCTAssertEqual(acts.map(\.kind), [.watchError])
        XCTAssertEqual(acts.first?.zone, .green)
    }

    func testExitedTreatedAsError() {
        let acts = FirstMate.evaluate(tx(.running, .exited), config: .default)
        XCTAssertEqual(acts.map(\.kind), [.watchError])
    }

    func testCompletionEmitsInspectGreen() {
        let acts = FirstMate.evaluate(tx(.running, .idle, completion: true), config: .default)
        XCTAssertTrue(acts.contains { $0.kind == .inspect && $0.zone == .green })
    }

    func testCompletionWithAutoCommitOnEmitsCommit() {
        var cfg = FirstMateConfig.default; cfg.autoCommit = true
        let acts = FirstMate.evaluate(tx(.running, .idle, completion: true), config: cfg)
        XCTAssertTrue(acts.contains { $0.kind == .autoCommit })
    }

    func testCompletionWithAutoCommitOffOmitsCommit() {
        let acts = FirstMate.evaluate(tx(.running, .idle, completion: true), config: .default)
        XCTAssertFalse(acts.contains { $0.kind == .autoCommit })
    }

    func testIdleWithoutCompletionEmitsNothing() {
        // Suggestions are no longer guessed from a status transition. They come
        // only from what the agent actually offered — a `.suggest` sentinel line
        // or an AskUserQuestion — which the `IngestOutcome` overload handles.
        // Going idle on its own says nothing about what to do next.
        let acts = FirstMate.evaluate(tx(.running, .idle, completion: false), config: .default)
        XCTAssertTrue(acts.isEmpty)
    }

    func testDisabledEmitsNothing() {
        var cfg = FirstMateConfig.default; cfg.enabled = false
        XCTAssertTrue(FirstMate.evaluate(tx(.running, .error), config: cfg).isEmpty)
    }

    func testAutoInspectOffOmitsInspect() {
        var cfg = FirstMateConfig.default; cfg.autoInspect = false
        let acts = FirstMate.evaluate(tx(.running, .idle, completion: true), config: cfg)
        XCTAssertFalse(acts.contains { $0.kind == .inspect })
    }
}
