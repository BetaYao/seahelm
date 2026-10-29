import XCTest
@testable import seahelm

final class ClaudeUsageSummaryProviderTests: XCTestCase {
    func testReadsRateLimitsFromStatuslineCache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("claude-statusline.json")
        try """
        {"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1777270800},"seven_day":{"used_percentage":13,"resets_at":1777759200}}}
        """.write(to: cache, atomically: true, encoding: .utf8)

        let reader = ClaudeStatuslineCacheReader(cacheURL: cache, staleInterval: 3600)
        let snapshot = try reader.read(now: Date(timeIntervalSince1970: 1_772_516_340))

        XCTAssertEqual(snapshot?.fiveHour?.usedPercent, 10)
        XCTAssertEqual(snapshot?.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_777_270_800))
        XCTAssertEqual(snapshot?.sevenDay?.usedPercent, 13)
        XCTAssertEqual(snapshot?.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1_777_759_200))
    }

    func testReadsFractionalSecondRateLimitReset() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("claude-statusline.json")
        try """
        {"rate_limits":{"five_hour":{"used_percentage":19,"resets_at":"2026-04-27T12:19:00.123Z"}}}
        """.write(to: cache, atomically: true, encoding: .utf8)

        let reader = ClaudeStatuslineCacheReader(cacheURL: cache, staleInterval: 3600)
        let snapshot = try reader.read(now: Date(timeIntervalSince1970: 1_772_516_340))

        XCTAssertEqual(snapshot?.fiveHour?.resetsAt, Self.iso8601WithFractionalSeconds.date(from: "2026-04-27T12:19:00.123Z"))
    }

    func testSnapshotIncludesFiveHourAndWeeklyRateLimits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("claude-statusline.json")
        try """
        {"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1777270800},"seven_day":{"used_percentage":13,"resets_at":1777759200}}}
        """.write(to: cache, atomically: true, encoding: .utf8)
        let provider = ClaudeUsageSummaryProvider(
            cacheReader: ClaudeStatuslineCacheReader(cacheURL: cache, staleInterval: 3600)
        )

        let snapshot = provider.snapshot(now: Date(timeIntervalSince1970: 1_772_516_340))

        XCTAssertEqual(snapshot.rateLimit?.usedPercent, 10)
        XCTAssertEqual(snapshot.rateLimit?.resetsAt, Date(timeIntervalSince1970: 1_777_270_800))
        XCTAssertEqual(snapshot.weeklyRateLimit?.usedPercent, 13)
        XCTAssertEqual(snapshot.weeklyRateLimit?.resetsAt, Date(timeIntervalSince1970: 1_777_759_200))
        XCTAssertNil(snapshot.todayTokens)
        XCTAssertFalse(snapshot.isStale)
    }

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
