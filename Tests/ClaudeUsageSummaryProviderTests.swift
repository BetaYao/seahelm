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

    func testAggregatesTodayTokensAndDedupesRequestIDs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("session.jsonl")
        try [
            #"{"timestamp":"2026-04-27T01:00:00Z","requestId":"req-1","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":40}}}"#,
            #"{"timestamp":"2026-04-27T01:01:00Z","requestId":"req-1","message":{"usage":{"input_tokens":999,"output_tokens":999}}}"#,
            #"{"timestamp":"2026-04-26T23:59:59Z","requestId":"old","message":{"usage":{"input_tokens":1000}}}"#
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let aggregator = ClaudeTranscriptUsageAggregator(rootURL: dir, calendar: calendar)
        let tokens = try aggregator.todayTokens(now: ISO8601DateFormatter().date(from: "2026-04-27T08:00:00Z")!)

        XCTAssertEqual(tokens, 100)
    }

    func testAggregatesIdenticalRowsWithoutRequestIDAsSeparateLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("session.jsonl")
        let row = #"{"timestamp":"2026-04-27T01:00:00Z","message":{"usage":{"input_tokens":7}}}"#
        try [row, row].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let aggregator = ClaudeTranscriptUsageAggregator(rootURL: dir, calendar: calendar)
        let tokens = try aggregator.todayTokens(now: ISO8601DateFormatter().date(from: "2026-04-27T08:00:00Z")!)

        XCTAssertEqual(tokens, 14)
    }

    func testAggregatesFractionalSecondTranscriptTimestamps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("session.jsonl")
        try #"{"timestamp":"2026-04-27T01:00:00.123Z","requestId":"req-1","message":{"usage":{"input_tokens":10}}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let aggregator = ClaudeTranscriptUsageAggregator(rootURL: dir, calendar: calendar)
        let tokens = try aggregator.todayTokens(now: ISO8601DateFormatter().date(from: "2026-04-27T08:00:00Z")!)

        XCTAssertEqual(tokens, 10)
    }

    func testMissingTranscriptRootThrowsInsteadOfReportingZero() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let aggregator = ClaudeTranscriptUsageAggregator(rootURL: missing, calendar: calendar)

        XCTAssertThrowsError(
            try aggregator.todayTokens(now: ISO8601DateFormatter().date(from: "2026-04-27T08:00:00Z")!)
        )
    }

    func testSnapshotDoesNotReportMissingTranscriptRootAsZero() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("claude-statusline.json")
        try """
        {"rate_limits":{"five_hour":{"used_percentage":19,"resets_at":"2026-04-27T12:19:00Z"}}}
        """.write(to: cache, atomically: true, encoding: .utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let provider = ClaudeUsageSummaryProvider(
            cacheReader: ClaudeStatuslineCacheReader(cacheURL: cache, staleInterval: 3600),
            transcriptAggregator: ClaudeTranscriptUsageAggregator(
                rootURL: dir.appendingPathComponent("missing"),
                calendar: calendar
            )
        )

        let snapshot = provider.snapshot(now: Date(timeIntervalSince1970: 1_772_516_340))

        XCTAssertEqual(snapshot.rateLimit?.usedPercent, 19)
        XCTAssertNil(snapshot.todayTokens)
        XCTAssertFalse(snapshot.isStale)
    }

    func testSnapshotIncludesFiveHourAndWeeklyRateLimits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("claude-statusline.json")
        try """
        {"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1777270800},"seven_day":{"used_percentage":13,"resets_at":1777759200}}}
        """.write(to: cache, atomically: true, encoding: .utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let provider = ClaudeUsageSummaryProvider(
            cacheReader: ClaudeStatuslineCacheReader(cacheURL: cache, staleInterval: 3600),
            transcriptAggregator: ClaudeTranscriptUsageAggregator(
                rootURL: dir.appendingPathComponent("missing"),
                calendar: calendar
            )
        )

        let snapshot = provider.snapshot(now: Date(timeIntervalSince1970: 1_772_516_340))

        XCTAssertEqual(snapshot.rateLimit?.usedPercent, 10)
        XCTAssertEqual(snapshot.rateLimit?.resetsAt, Date(timeIntervalSince1970: 1_777_270_800))
        XCTAssertEqual(snapshot.weeklyRateLimit?.usedPercent, 13)
        XCTAssertEqual(snapshot.weeklyRateLimit?.resetsAt, Date(timeIntervalSince1970: 1_777_759_200))
        XCTAssertNil(snapshot.todayTokens)
        XCTAssertFalse(snapshot.isStale)
    }

    func testSnapshotTreatsFreshTranscriptTokensAsPartialDataWhenRateLimitIsUnavailable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"timestamp":"2026-04-27T01:00:00Z","requestId":"req-1","message":{"usage":{"input_tokens":10}}}"#
            .write(to: project.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let provider = ClaudeUsageSummaryProvider(
            cacheReader: ClaudeStatuslineCacheReader(
                cacheURL: dir.appendingPathComponent("missing-cache.json"),
                staleInterval: 3600
            ),
            transcriptAggregator: ClaudeTranscriptUsageAggregator(rootURL: dir, calendar: calendar)
        )

        let snapshot = provider.snapshot(now: ISO8601DateFormatter().date(from: "2026-04-27T08:00:00Z")!)

        XCTAssertNil(snapshot.rateLimit)
        XCTAssertEqual(snapshot.todayTokens, 10)
        XCTAssertFalse(snapshot.isStale)
    }

    func testSkipsTranscriptFilesOlderThanModificationGraceInterval() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let stale = project.appendingPathComponent("stale.jsonl")
        let current = project.appendingPathComponent("current.jsonl")
        try #"{"timestamp":"2026-04-27T01:00:00Z","requestId":"stale","message":{"usage":{"input_tokens":1000}}}"#
            .write(to: stale, atomically: true, encoding: .utf8)
        try #"{"timestamp":"2026-04-27T02:00:00Z","requestId":"current","message":{"usage":{"input_tokens":25}}}"#
            .write(to: current, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-04-25T00:00:00Z")!],
            ofItemAtPath: stale.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-04-27T02:00:00Z")!],
            ofItemAtPath: current.path
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let aggregator = ClaudeTranscriptUsageAggregator(
            rootURL: dir,
            calendar: calendar,
            modificationGraceInterval: 24 * 60 * 60
        )

        let tokens = try aggregator.todayTokens(now: ISO8601DateFormatter().date(from: "2026-04-27T08:00:00Z")!)

        XCTAssertEqual(tokens, 25)
    }

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
