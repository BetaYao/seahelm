import XCTest
@testable import seahelm

final class WorktreeGroupingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func item(
        _ path: String,
        repo: String,
        status: SailorStatus = .idle,
        activity: Date? = nil,
        main: Bool = false,
        created: Date = .distantPast
    ) -> WorktreeGroupingItem {
        WorktreeGroupingItem(
            id: path,
            path: path,
            repository: repo,
            status: status,
            lastActivityAt: activity,
            isMainWorktree: main,
            creationDate: created
        )
    }

    func testRepositoryGroupsRemainInFirstSeenOrderAndNormalizeEmptyName() {
        let groups = WorktreeGrouping.groups([
            item("/beta/linked", repo: "beta"),
            item("/unknown", repo: ""),
            item("/alpha", repo: "alpha"),
            item("/beta/main", repo: "beta", main: true),
        ], mode: .repository, now: now)

        XCTAssertEqual(groups.map(\.title), ["beta", "Unknown repository", "alpha"])
        XCTAssertEqual(groups.map(\.id), [
            .repository("beta"),
            .repository("Unknown repository"),
            .repository("alpha"),
        ])
    }

    func testRepositoryRowsSortMainFirstThenCreationDateThenPath() {
        let old = Date(timeIntervalSince1970: 10)
        let new = Date(timeIntervalSince1970: 20)
        let groups = WorktreeGrouping.groups([
            item("/repo/z-new", repo: "repo", created: new),
            item("/repo/z-old", repo: "repo", created: old),
            item("/repo/main", repo: "repo", main: true, created: new),
            item("/repo/a-old", repo: "repo", created: old),
        ], mode: .repository, now: now)

        XCTAssertEqual(groups[0].items.map(\.path), [
            "/repo/main", "/repo/a-old", "/repo/z-old", "/repo/z-new",
        ])
    }

    func testStatusGroupsUseApprovedOrderAndTitles() {
        let groups = WorktreeGrouping.groups([
            item("/unknown", repo: "repo", status: .unknown),
            item("/dormant", repo: "repo", status: .exited),
            item("/error", repo: "repo", status: .error),
            item("/idle", repo: "repo", status: .idle),
            item("/running", repo: "repo", status: .running),
            item("/waiting", repo: "repo", status: .waiting),
        ], mode: .status, now: now)

        XCTAssertEqual(groups.map(\.title), [
            "Needs input", "Running", "Idle", "Error", "Dormant", "Unknown",
        ])
        XCTAssertEqual(groups.compactMap(\.status), [
            .waiting, .running, .idle, .error, .exited, .unknown,
        ])
    }

    func testStatusRowsSortByLatestActivityThenPath() {
        let recent = now.addingTimeInterval(-10)
        let old = now.addingTimeInterval(-30)
        let groups = WorktreeGrouping.groups([
            item("/none-z", repo: "repo", status: .running),
            item("/old", repo: "repo", status: .running, activity: old),
            item("/recent-z", repo: "repo", status: .running, activity: recent),
            item("/recent-a", repo: "repo", status: .running, activity: recent),
            item("/none-a", repo: "repo", status: .running),
        ], mode: .status, now: now)

        XCTAssertEqual(groups[0].items.map(\.path), [
            "/recent-a", "/recent-z", "/old", "/none-a", "/none-z",
        ])
    }

    func testActivityTimeBucketsUseUTCNowAndClampFutureActivity() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-20T12:00:00Z"))
        let groups = WorktreeGrouping.groups([
            item("/future", repo: "repo", activity: now.addingTimeInterval(60)),
            item("/hour", repo: "repo", activity: now.addingTimeInterval(-3_599)),
            item("/today", repo: "repo", activity: now.addingTimeInterval(-7_200)),
            item("/recent-seven", repo: "repo", activity: now.addingTimeInterval(-2 * 86_400)),
            item("/earlier", repo: "repo", activity: now.addingTimeInterval(-8 * 86_400)),
            item("/none", repo: "repo"),
        ], mode: .activityTime, now: now, calendar: utcCalendar)

        XCTAssertEqual(groups.map(\.title), [
            "Recent hour", "Today", "Recent 7 days", "Earlier", "No activity",
        ])
        XCTAssertEqual(groups[0].items.map(\.path), ["/future", "/hour"])
    }

    func testActivityTimeBucketsHonorExactHourAndSevenDayBoundaries() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-20T12:00:00Z"))
        let groups = WorktreeGrouping.groups([
            item("/exact-hour", repo: "repo", activity: now.addingTimeInterval(-3_600)),
            item("/under-seven", repo: "repo", activity: now.addingTimeInterval(-(7 * 86_400 - 1))),
            item("/exact-seven", repo: "repo", activity: now.addingTimeInterval(-7 * 86_400)),
        ], mode: .activityTime, now: now, calendar: utcCalendar)

        XCTAssertEqual(groups.map(\.id), [
            .activity(.today), .activity(.recentSevenDays), .activity(.earlier),
        ])
        XCTAssertEqual(groups.map { $0.items.map(\.path) }, [
            ["/exact-hour"], ["/under-seven"], ["/exact-seven"],
        ])
    }

    func testActivityRowsSortByLatestActivityThenPath() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-20T12:00:00Z"))
        let tied = now.addingTimeInterval(-7_200)
        let groups = WorktreeGrouping.groups([
            item("/today-z", repo: "repo", activity: tied),
            item("/today-old", repo: "repo", activity: tied.addingTimeInterval(-60)),
            item("/today-a", repo: "repo", activity: tied),
            item("/none-z", repo: "repo"),
            item("/none-a", repo: "repo"),
        ], mode: .activityTime, now: now, calendar: utcCalendar)

        XCTAssertEqual(groups[0].items.map(\.path), ["/today-a", "/today-z", "/today-old"])
        XCTAssertEqual(groups[1].items.map(\.path), ["/none-a", "/none-z"])
    }

    func testPreferenceRoundTripsAndInvalidOrMissingValueFallsBack() {
        let suite = "WorktreeGroupingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = WorktreeGroupingPreference(defaults: defaults)

        XCTAssertEqual(preference.load(), .repository)
        preference.save(.activityTime)
        XCTAssertEqual(preference.load(), .activityTime)
        XCTAssertEqual(defaults.string(forKey: WorktreeGroupingPreference.key), "activityTime")

        defaults.set("broken", forKey: WorktreeGroupingPreference.key)
        XCTAssertEqual(preference.load(), .repository)
    }
}
