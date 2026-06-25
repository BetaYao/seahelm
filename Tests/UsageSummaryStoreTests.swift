import XCTest
@testable import seahelm

final class UsageSummaryStoreTests: XCTestCase {
    func testResolveSnapshotKeepsCachedRateLimitWhenRefreshMissesIt() {
        var cache = UsageSummaryStore.ProviderSnapshotCache(provider: .claude)
        let cachedSnapshot = UsageSnapshot(
            provider: .claude,
            rateLimit: UsageRateLimitWindow(usedPercent: 19, resetsAt: Date(timeIntervalSince1970: 1_772_532_000)),
            todayTokens: 120_000,
            updatedAt: Date(timeIntervalSince1970: 1_772_523_000),
            isStale: false
        )
        cache.ingest(cachedSnapshot, now: Date(timeIntervalSince1970: 1_772_523_000))
        let candidate = UsageSnapshot(
            provider: .claude,
            rateLimit: nil,
            todayTokens: 130_000,
            updatedAt: Date(timeIntervalSince1970: 1_772_523_600),
            isStale: true
        )

        let result = UsageSummaryStore.resolveSnapshotForDisplay(
            candidate: candidate,
            cached: cache,
            now: Date(timeIntervalSince1970: 1_772_523_600),
            maxCacheAge: 10 * 60
        )

        XCTAssertEqual(result.snapshot.provider, .claude)
        XCTAssertEqual(result.snapshot.rateLimit, cachedSnapshot.rateLimit)
        XCTAssertEqual(result.snapshot.todayTokens, 130_000)
        XCTAssertEqual(result.snapshot.updatedAt, candidate.updatedAt)
        XCTAssertTrue(result.snapshot.isStale)
    }

    func testResolveSnapshotKeepsCachedWeeklyRateLimitWhenRefreshMissesIt() {
        var cache = UsageSummaryStore.ProviderSnapshotCache(provider: .claude)
        let cachedSnapshot = UsageSnapshot(
            provider: .claude,
            rateLimit: UsageRateLimitWindow(usedPercent: 10, resetsAt: Date(timeIntervalSince1970: 1_777_270_800)),
            weeklyRateLimit: UsageRateLimitWindow(usedPercent: 13, resetsAt: Date(timeIntervalSince1970: 1_777_759_200)),
            todayTokens: nil,
            updatedAt: Date(timeIntervalSince1970: 1_772_523_000),
            isStale: false
        )
        cache.ingest(cachedSnapshot, now: Date(timeIntervalSince1970: 1_772_523_000))
        let candidate = UsageSnapshot(
            provider: .claude,
            rateLimit: cachedSnapshot.rateLimit,
            weeklyRateLimit: nil,
            todayTokens: nil,
            updatedAt: Date(timeIntervalSince1970: 1_772_523_600),
            isStale: false
        )

        let result = UsageSummaryStore.resolveSnapshotForDisplay(
            candidate: candidate,
            cached: cache,
            now: Date(timeIntervalSince1970: 1_772_523_600),
            maxCacheAge: 10 * 60
        )

        XCTAssertEqual(result.snapshot.rateLimit, candidate.rateLimit)
        XCTAssertEqual(result.snapshot.weeklyRateLimit, cachedSnapshot.weeklyRateLimit)
        XCTAssertEqual(result.snapshot.updatedAt, candidate.updatedAt)
        XCTAssertFalse(result.snapshot.isStale)
    }

    func testResolveSnapshotKeepsCachedTodayTokensWhenRefreshMissesThem() {
        var cache = UsageSummaryStore.ProviderSnapshotCache(provider: .codex)
        let cachedSnapshot = UsageSnapshot(
            provider: .codex,
            rateLimit: UsageRateLimitWindow(usedPercent: 40, resetsAt: nil),
            todayTokens: 34_000,
            updatedAt: Date(timeIntervalSince1970: 1_772_523_000),
            isStale: false
        )
        cache.ingest(cachedSnapshot, now: Date(timeIntervalSince1970: 1_772_523_000))
        let candidate = UsageSnapshot(
            provider: .codex,
            rateLimit: UsageRateLimitWindow(usedPercent: 42, resetsAt: nil),
            todayTokens: nil,
            updatedAt: Date(timeIntervalSince1970: 1_772_523_600),
            isStale: false
        )

        let result = UsageSummaryStore.resolveSnapshotForDisplay(
            candidate: candidate,
            cached: cache,
            now: Date(timeIntervalSince1970: 1_772_523_600),
            maxCacheAge: 10 * 60
        )

        XCTAssertEqual(result.snapshot.provider, .codex)
        XCTAssertEqual(result.snapshot.rateLimit, candidate.rateLimit)
        XCTAssertEqual(result.snapshot.todayTokens, cachedSnapshot.todayTokens)
        XCTAssertEqual(result.snapshot.updatedAt, candidate.updatedAt)
        XCTAssertFalse(result.snapshot.isStale)
    }

    func testResolveSnapshotExpiresCachedFieldsAfterMaxAge() {
        var cache = UsageSummaryStore.ProviderSnapshotCache(provider: .claude)
        cache.ingest(
            UsageSnapshot(
                provider: .claude,
                rateLimit: UsageRateLimitWindow(usedPercent: 19, resetsAt: nil),
                todayTokens: 120_000,
                updatedAt: Date(timeIntervalSince1970: 1_772_523_000),
                isStale: false
            ),
            now: Date(timeIntervalSince1970: 1_772_523_000)
        )
        let candidate = UsageSnapshot(
            provider: .claude,
            rateLimit: nil,
            todayTokens: nil,
            updatedAt: Date(timeIntervalSince1970: 1_772_524_000),
            isStale: true
        )

        let result = UsageSummaryStore.resolveSnapshotForDisplay(
            candidate: candidate,
            cached: cache,
            now: Date(timeIntervalSince1970: 1_772_524_000),
            maxCacheAge: 10 * 60
        )

        XCTAssertNil(result.snapshot.rateLimit)
        XCTAssertNil(result.snapshot.todayTokens)
        XCTAssertNil(result.snapshot.updatedAt)
        XCTAssertTrue(result.snapshot.isStale)
    }

    func testResolveSnapshotDoesNotCarryTodayTokensAcrossLocalDayBoundary() {
        var cache = UsageSummaryStore.ProviderSnapshotCache(provider: .codex)
        let localDay = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_772_524_800))
        let nextLocalDay = Calendar.current.date(byAdding: .day, value: 1, to: localDay)!
        let cachedAt = Calendar.current.date(byAdding: .minute, value: -1, to: nextLocalDay)!
        cache.ingest(
            UsageSnapshot(
                provider: .codex,
                rateLimit: UsageRateLimitWindow(usedPercent: 40, resetsAt: nil),
                todayTokens: 34_000,
                updatedAt: cachedAt,
                isStale: false
            ),
            now: cachedAt
        )
        let now = Calendar.current.date(byAdding: .minute, value: 1, to: nextLocalDay)!
        let candidate = UsageSnapshot(
            provider: .codex,
            rateLimit: UsageRateLimitWindow(usedPercent: 42, resetsAt: nil),
            todayTokens: nil,
            updatedAt: now,
            isStale: false
        )

        let result = UsageSummaryStore.resolveSnapshotForDisplay(
            candidate: candidate,
            cached: cache,
            now: now,
            maxCacheAge: 10 * 60
        )

        XCTAssertEqual(result.snapshot.rateLimit, candidate.rateLimit)
        XCTAssertNil(result.snapshot.todayTokens)
        XCTAssertEqual(result.snapshot.updatedAt, candidate.updatedAt)
        XCTAssertFalse(result.snapshot.isStale)
    }
}
