import Foundation

/// A five-field cron expression — minute, hour, day of month, month, day of
/// week — for `on: { schedule: … }` rules. `*`, lists (`1,15`), ranges
/// (`1-5`), steps (`*/10`, `0-30/5`); day of week 0–7 with both 0 and 7 as
/// Sunday. As in cron, when both day fields are restricted either may match.
struct CronSchedule: Equatable {
    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    let daysOfWeek: Set<Int>
    private let domRestricted: Bool
    private let dowRestricted: Bool

    init?(_ expression: String) {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5,
              let mi = Self.field(fields[0], 0...59), let h = Self.field(fields[1], 0...23),
              let dom = Self.field(fields[2], 1...31), let mo = Self.field(fields[3], 1...12),
              let dow = Self.field(fields[4], 0...7) else { return nil }
        minutes = mi; hours = h; daysOfMonth = dom; months = mo
        daysOfWeek = Set(dow.map { $0 == 7 ? 0 : $0 })
        domRestricted = fields[2] != "*"
        dowRestricted = fields[4] != "*"
    }

    func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let minute = c.minute, let hour = c.hour, let day = c.day, let month = c.month,
              let weekday = c.weekday else { return false }
        guard minutes.contains(minute), hours.contains(hour), months.contains(month) else { return false }
        let dom = daysOfMonth.contains(day)
        let dow = daysOfWeek.contains(weekday - 1)   // Calendar: 1 = Sunday
        if domRestricted && dowRestricted { return dom || dow }
        return dom && dow
    }

    private static func field(_ text: String, _ range: ClosedRange<Int>) -> Set<Int>? {
        var out = Set<Int>()
        for part in text.split(separator: ",") {
            let pieces = part.split(separator: "/", maxSplits: 1).map(String.init)
            let step = pieces.count == 2 ? Int(pieces[1]) : 1
            guard let step, step > 0 else { return nil }
            let span: ClosedRange<Int>
            if pieces[0] == "*" {
                span = range
            } else if let dash = pieces[0].firstIndex(of: "-") {
                guard let lo = Int(pieces[0][..<dash]), let hi = Int(pieces[0][pieces[0].index(after: dash)...]),
                      lo <= hi, range.contains(lo), range.contains(hi) else { return nil }
                span = lo...hi
            } else {
                guard let v = Int(pieces[0]), range.contains(v) else { return nil }
                span = pieces.count == 2 ? v...range.upperBound : v...v
            }
            out.formUnion(stride(from: span.lowerBound, through: span.upperBound, by: step))
        }
        return out.isEmpty ? nil : out
    }
}
