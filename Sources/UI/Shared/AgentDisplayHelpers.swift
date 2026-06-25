import AppKit

enum AgentDisplayHelpers {
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
}
