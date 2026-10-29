import Foundation

private enum ClaudeISO8601Parser {
    private static let defaultFormatter = ISO8601DateFormatter()
    private static let fractionalSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(from string: String) -> Date? {
        defaultFormatter.date(from: string) ?? fractionalSecondsFormatter.date(from: string)
    }
}

struct ClaudeStatuslineRateLimit: Equatable {
    let usedPercent: Int
    let resetsAt: Date?
}

struct ClaudeStatuslineRateLimits: Equatable {
    let fiveHour: ClaudeStatuslineRateLimit?
    let sevenDay: ClaudeStatuslineRateLimit?
}

struct ClaudeStatuslineCacheReader {
    let cacheURL: URL
    let staleInterval: TimeInterval

    func read(now: Date = Date()) throws -> ClaudeStatuslineRateLimits? {
        let values = try cacheURL.resourceValues(forKeys: [.contentModificationDateKey])
        guard let modified = values.contentModificationDate,
              now.timeIntervalSince(modified) <= staleInterval else { return nil }
        let data = try Data(contentsOf: cacheURL)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rateLimits = root?["rate_limits"] as? [String: Any]
        let fiveHour = Self.parseWindow(rateLimits?["five_hour"] as? [String: Any])
        let sevenDay = Self.parseWindow(rateLimits?["seven_day"] as? [String: Any])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return ClaudeStatuslineRateLimits(fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private static func parseWindow(_ window: [String: Any]?) -> ClaudeStatuslineRateLimit? {
        guard let used = intValue(window?["used_percentage"]) else { return nil }
        let resetsAt = dateValue(window?["resets_at"])
        return ClaudeStatuslineRateLimit(usedPercent: used, resetsAt: resetsAt)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let string = value as? String {
            if let date = ClaudeISO8601Parser.date(from: string) {
                return date
            }
            return TimeInterval(string).map { Date(timeIntervalSince1970: $0) }
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        return nil
    }
}

struct ClaudeUsageSummaryProvider {
    let cacheReader: ClaudeStatuslineCacheReader

    func snapshot(now: Date = Date()) -> UsageSnapshot {
        let rateLimits = try? cacheReader.read(now: now)
        let fiveHour = rateLimits?.fiveHour
        let sevenDay = rateLimits?.sevenDay
        return UsageSnapshot(
            provider: .claude,
            rateLimit: fiveHour.map { UsageRateLimitWindow(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) },
            weeklyRateLimit: sevenDay.map { UsageRateLimitWindow(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) },
            todayTokens: nil,
            updatedAt: now,
            isStale: fiveHour == nil && sevenDay == nil
        )
    }
}
