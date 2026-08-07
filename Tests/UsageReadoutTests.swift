import XCTest
@testable import seahelm

final class UsageReadoutTests: XCTestCase {
    private func claudeSnapshot(fiveHour: Int, sevenDay: Int) -> UsageSnapshot {
        UsageSnapshot(
            provider: .claude,
            rateLimit: UsageRateLimitWindow(usedPercent: fiveHour, resetsAt: Date(timeIntervalSince1970: 14_460)),
            weeklyRateLimit: UsageRateLimitWindow(usedPercent: sevenDay, resetsAt: Date(timeIntervalSince1970: 21_660)),
            todayTokens: 1_000,
            updatedAt: Date(timeIntervalSince1970: 0),
            isStale: false
        )
    }

    func testClaudeReadoutCarriesBothWindowsWithResetCountdowns() throws {
        let readout = try XCTUnwrap(UsageSummaryFormatter.readout(
            for: claudeSnapshot(fiveHour: 11, sevenDay: 2),
            now: Date(timeIntervalSince1970: 0)
        ))

        XCTAssertEqual(readout.provider, .claude)
        XCTAssertEqual(readout.segments.map(\.label), ["5h", "7d"])
        XCTAssertEqual(readout.segments.map(\.percentText), ["11%", "2%"])
        XCTAssertEqual(readout.segments.map(\.resetText), ["4h 1m", "6h 1m"])
        XCTAssertEqual(readout.segments.map(\.severity), [.ok, .ok])
    }

    func testSeverityEscalatesWithUsage() {
        XCTAssertEqual(UsageReadoutSegment.Severity(usedPercent: 0), .ok)
        XCTAssertEqual(UsageReadoutSegment.Severity(usedPercent: 59), .ok)
        XCTAssertEqual(UsageReadoutSegment.Severity(usedPercent: 60), .warn)
        XCTAssertEqual(UsageReadoutSegment.Severity(usedPercent: 84), .warn)
        XCTAssertEqual(UsageReadoutSegment.Severity(usedPercent: 85), .critical)
        XCTAssertEqual(UsageReadoutSegment.Severity(usedPercent: 100), .critical)
    }

    func testProviderWithoutRateLimitsUsesPlaceholderReadout() {
        let empty = UsageSnapshot(provider: .codex, rateLimit: nil, todayTokens: nil, updatedAt: nil, isStale: true)
        let codex = UsageSummaryFormatter.readout(for: empty)
        XCTAssertEqual(codex?.segments.map(\.label), ["quota"])
        XCTAssertEqual(codex?.segments.map(\.percentText), ["--"])
        XCTAssertEqual(codex?.segments.map(\.severity), [.unknown])

        let readouts = UsageSummaryFormatter.readouts(
            claude: claudeSnapshot(fiveHour: 11, sevenDay: 2),
            codex: empty,
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(readouts.map(\.provider), [.claude, .codex])
    }

    @MainActor
    func testPillFlattensEveryWindowAcrossProviders() {
        let model = IslandModel()
        model.setUsageReadouts(UsageSummaryFormatter.readouts(
            claude: claudeSnapshot(fiveHour: 11, sevenDay: 2),
            codex: UsageSnapshot(
                provider: .codex,
                rateLimit: UsageRateLimitWindow(usedPercent: 90, resetsAt: nil),
                todayTokens: nil,
                updatedAt: Date(timeIntervalSince1970: 0),
                isStale: false
            ),
            now: Date(timeIntervalSince1970: 0)
        ))

        XCTAssertEqual(model.pillFrames.map(\.segment.percentText), ["11%", "2%", "90%"])
        XCTAssertEqual(model.pillUsage?.segment.percentText, "11%")
        XCTAssertEqual(model.wingUsageWidth, IslandModel.pillUsageWidth)
    }

    /// A waiting suggestion owns the left wing — usage steps aside, and the
    /// pill must shrink back with it.
    @MainActor
    func testPendingOrderSuppressesPillUsageAndItsWidth() {
        let model = IslandModel()
        model.setUsageReadouts(UsageSummaryFormatter.readouts(
            claude: claudeSnapshot(fiveHour: 11, sevenDay: 2),
            codex: UsageSnapshot(provider: .codex, rateLimit: nil, todayTokens: nil, updatedAt: nil, isStale: true),
            now: Date(timeIntervalSince1970: 0)
        ))
        let widthWithUsage = model.closedWidth

        model.orders = [PendingOrder(id: "o1", action: FirstMateAction(
            kind: .suggestNextOrder, zone: .red, worktreePath: "/wt", branch: "b",
            project: "p", terminalID: "t", message: "m", options: ["a", "b"]
        ))]

        XCTAssertNil(model.pillUsage)
        XCTAssertEqual(model.wingUsageWidth, 0)
        XCTAssertEqual(model.closedWidth, widthWithUsage - IslandModel.pillUsageWidth * 2)
    }
}
