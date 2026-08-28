import XCTest
@testable import seahelm

/// The automatic trigger. Everything here is about *when* a round runs — the
/// round itself is covered by IntegrationWorktreeTests.
final class IntegrationCoordinatorTests: XCTestCase {

    private var tempDir: URL!
    private var checkout: String!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-intcoord-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        checkout = tempDir.appendingPathComponent("integration").path
        try? FileManager.default.createDirectory(atPath: checkout, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    // MARK: - what triggers

    func testFinishingATurnSchedulesARound() {
        let harness = Harness(checkout: checkout)
        harness.coordinator.handle(harness.transition(from: .running, to: .idle))
        harness.waitForRound()
        XCTAssertEqual(harness.rounds, 1)
    }

    /// Only the edge *out of* running is a stage of work reaching a rest.
    func testOtherEdgesDoNotSchedule() {
        let harness = Harness(checkout: checkout)
        harness.coordinator.handle(harness.transition(from: .idle, to: .running))
        harness.coordinator.handle(harness.transition(from: .waiting, to: .idle))
        harness.coordinator.handle(harness.transition(from: .running, to: .running))
        harness.waitForRound(expecting: 0)
        XCTAssertEqual(harness.rounds, 0)
    }

    /// A burst of agents finishing together is one round, not one each.
    func testConcurrentFinishesCoalesceIntoOneRound() {
        let harness = Harness(checkout: checkout)
        for _ in 0..<5 {
            harness.coordinator.handle(harness.transition(from: .running, to: .idle))
        }
        harness.waitForRound()
        XCTAssertEqual(harness.rounds, 1)
    }

    // MARK: - what suppresses

    func testDisabledDoesNothing() {
        let harness = Harness(checkout: checkout, enabled: false)
        harness.coordinator.handle(harness.transition(from: .running, to: .idle))
        harness.waitForRound(expecting: 0)
        XCTAssertEqual(harness.rounds, 0)
    }

    /// Opting in is creating the checkout. A repo without one is never touched,
    /// so switching this on cannot conjure directories on disk.
    func testRepoWithoutACheckoutIsNeverTouched() {
        let harness = Harness(checkout: tempDir.appendingPathComponent("absent").path)
        harness.coordinator.handle(harness.transition(from: .running, to: .idle))
        harness.waitForRound(expecting: 0)
        XCTAssertEqual(harness.rounds, 0)
    }

    /// Publishing pulls files out from under whatever is running in the
    /// checkout, so a busy one is skipped rather than built for.
    func testBusyCheckoutSkipsTheRound() {
        let harness = Harness(checkout: checkout, checkoutBusy: true)
        harness.coordinator.handle(harness.transition(from: .running, to: .idle))
        harness.waitForRound(expecting: 0)
        XCTAssertEqual(harness.rounds, 0)
    }

    // MARK: - reporting

    func testReportsAreForwarded() {
        let harness = Harness(checkout: checkout)
        harness.coordinator.handle(harness.transition(from: .running, to: .idle))
        harness.waitForRound()
        XCTAssertEqual(harness.reports.count, 1)
        XCTAssertEqual(harness.reports.first?.integrationWorktreePath, checkout)
    }

    /// A round that cannot run must not take the coordinator down with it.
    func testAFailedRoundIsSwallowed() {
        let harness = Harness(checkout: checkout, roundThrows: true)
        harness.coordinator.handle(harness.transition(from: .running, to: .idle))
        harness.waitForRound(expecting: 0)
        XCTAssertTrue(harness.reports.isEmpty)
        XCTAssertEqual(harness.rounds, 1, "it was attempted")
    }

    // MARK: - harness

    private final class Harness {
        private(set) var rounds = 0
        private(set) var reports: [IntegrationRunReport] = []
        let coordinator: IntegrationCoordinator
        private let checkout: String

        init(checkout: String, enabled: Bool = true, checkoutBusy: Bool = false, roundThrows: Bool = false) {
            self.checkout = checkout
            var roundCount = 0
            var collected: [IntegrationRunReport] = []
            let box = Box()
            coordinator = IntegrationCoordinator(
                coalesceWindow: 0.05,
                isEnabled: { enabled },
                repoRoot: { _ in "/repo" },
                worktrees: { _ in [] },
                integrationPath: { _ in checkout },
                isCheckoutBusy: { _ in checkoutBusy },
                onReport: { report, _ in collected.append(report); box.reports = collected },
                runRound: { _, path, _ in
                    roundCount += 1
                    box.rounds = roundCount
                    if roundThrows { throw IntegrationRunError.noBaseRef }
                    return IntegrationRunReport(
                        integrationWorktreePath: path,
                        result: IntegrationResult(commit: "c", tree: "t", base: "b",
                                                  included: [], excluded: [], conflictedPaths: []),
                        outcome: .unchanged(commit: "c"),
                        unsnapshotable: [],
                        committedOnly: []
                    )
                }
            )
            self.box = box
        }

        private let box: Box
        final class Box { var rounds = 0; var reports: [IntegrationRunReport] = [] }

        func transition(from old: AgentStatus, to new: AgentStatus) -> StatusTransition {
            StatusTransition(worktreePath: "/repo/agent", branch: "b", project: "p", terminalID: "t",
                             oldStatus: old, newStatus: new, holdSeconds: 0, isCompletionSignal: true)
        }

        /// The coalesce window plus room for the background hop back. A case
        /// expecting nothing still has to wait out the window to prove it.
        func waitForRound(expecting expected: Int = 1) {
            let deadline = Date().addingTimeInterval(coordinator.coalesceWindow + 0.6)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                if expected > 0, box.rounds >= expected, box.reports.count >= expected { break }
            }
            rounds = box.rounds
            reports = box.reports
        }
    }
}
