import AppKit

enum SailorDisplayHelpers {
    static func statusColor(_ status: String) -> NSColor {
        switch status {
        case "running": return SemanticColors.running
        case "waiting": return SemanticColors.waiting
        case "error": return SemanticColors.danger
        default: return SemanticColors.idle
        }
    }

    static func compactDuration(_ hms: String) -> String {
        let parts = hms.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return hms }
        let (h, m, s) = (parts[0], parts[1], parts[2])
        if h > 0 { return "\(h)h\(String(format: "%02d", m))m" }
        if m > 0 { return "\(m)m\(String(format: "%02d", s))s" }
        return "\(s)s"
    }

    /// Format a TimeInterval (seconds) as "HH:MM:SS"
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Compact "time since last activity" label, e.g. "just now", "3m", "2h", "1d".
    /// Returns an empty string when we have no activity timestamp at all.
    static func relativeAge(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let secs = max(0, Int(now.timeIntervalSince(date)))
        if secs < 10 { return "just now" }
        if secs < 60 { return "\(secs)s" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        return "\(days)d"
    }
}
