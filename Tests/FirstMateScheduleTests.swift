import XCTest
@testable import seahelm

final class FirstMateScheduleTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    /// 2026-11-02 is a Monday.
    private func at(_ day: Int, _ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    // MARK: - cron

    func testWeekdayMornings() {
        let cron = CronSchedule("0 9 * * 1-5")!
        XCTAssertTrue(cron.matches(at(2, 9, 0), calendar: cal), "Monday 09:00")
        XCTAssertFalse(cron.matches(at(2, 9, 1), calendar: cal))
        XCTAssertFalse(cron.matches(at(1, 9, 0), calendar: cal), "Sunday")
        XCTAssertTrue(cron.matches(at(6, 9, 0), calendar: cal), "Friday")
    }

    func testStepsListsAndSunday() {
        XCTAssertTrue(CronSchedule("*/15 * * * *")!.matches(at(3, 4, 45), calendar: cal))
        XCTAssertFalse(CronSchedule("*/15 * * * *")!.matches(at(3, 4, 50), calendar: cal))
        XCTAssertTrue(CronSchedule("0 8,18 * * *")!.matches(at(3, 18, 0), calendar: cal))
        XCTAssertTrue(CronSchedule("0 10 * * 7")!.matches(at(1, 10, 0), calendar: cal), "7 is Sunday too")
        XCTAssertTrue(CronSchedule("0 10 * * 0")!.matches(at(1, 10, 0), calendar: cal))
    }

    func testEitherDayFieldMatchesWhenBothAreSet() {
        let cron = CronSchedule("0 9 1 * 1")!   // the 1st, or any Monday
        XCTAssertTrue(cron.matches(at(2, 9, 0), calendar: cal), "a Monday that is not the 1st")
        XCTAssertTrue(cron.matches(at(1, 9, 0), calendar: cal), "the 1st, a Sunday")
        XCTAssertFalse(cron.matches(at(3, 9, 0), calendar: cal))
    }

    func testNonsenseIsRefused() {
        for bad in ["", "* * * *", "60 * * * *", "* 24 * * *", "*/0 * * * *", "5-1 * * * *", "a * * * *"] {
            XCTAssertNil(CronSchedule(bad), bad)
        }
        XCTAssertThrowsError(try AutomationConfig.parse(
            yaml: "rules:\n  - name: x\n    on: { schedule: \"99 * * * *\" }\n    brief: b"))
    }

    func testTriageShipsButIsOff() {
        let triage = AutomationConfig.builtIn.rules.first { $0.name == "triage-issues" }
        XCTAssertNotNil(triage)
        XCTAssertEqual(triage?.enabled, false)
        XCTAssertTrue(AutomationConfig.builtIn.rules(for: .schedule("0 9 * * 1-5")).isEmpty)
    }
}
