import Foundation

enum UsageProvider: String, Codable, Equatable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

struct UsageRateLimitWindow: Codable, Equatable {
    let usedPercent: Int
    let resetsAt: Date?
    /// What the window covers ("5h", "7d", "quota"). Nil falls back to the
    /// caller's default — Codex reports window lengths that vary by plan, so
    /// it names its own; Claude's two windows are fixed.
    var label: String?

    init(usedPercent: Int, resetsAt: Date?, label: String? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.label = label
    }

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    var progress: Double {
        Double(max(0, min(100, usedPercent))) / 100.0
    }
}

struct UsageSnapshot: Equatable {
    let provider: UsageProvider
    let rateLimit: UsageRateLimitWindow?
    let weeklyRateLimit: UsageRateLimitWindow?
    let todayTokens: Int?
    let updatedAt: Date?
    let isStale: Bool

    init(
        provider: UsageProvider,
        rateLimit: UsageRateLimitWindow?,
        weeklyRateLimit: UsageRateLimitWindow? = nil,
        todayTokens: Int?,
        updatedAt: Date?,
        isStale: Bool
    ) {
        self.provider = provider
        self.rateLimit = rateLimit
        self.weeklyRateLimit = weeklyRateLimit
        self.todayTokens = todayTokens
        self.updatedAt = updatedAt
        self.isStale = isStale
    }
}

/// One rate-limit window as the island renders it — "5h 11% 4h1m".
struct UsageReadoutSegment: Equatable {
    /// Coarse bucket for the percentage's tint. Keyed to how much is *used*,
    /// so a fresh window reads green and an almost-spent one reads red.
    enum Severity: Equatable {
        case ok
        case warn
        case critical

        init(usedPercent: Int) {
            switch usedPercent {
            case ..<60: self = .ok
            case ..<85: self = .warn
            default: self = .critical
            }
        }
    }

    let label: String
    let percentText: String
    let severity: Severity
    let resetText: String?
}

/// A provider's rate-limit windows. Shown in full in the opened island header;
/// the closed pill rotates through `pillSegments` one window at a time.
struct UsageReadout: Equatable, Identifiable {
    let provider: UsageProvider
    /// Asset-catalog name of the vendor's own mark (vector, template-rendered).
    let logoName: String
    let segments: [UsageReadoutSegment]

    var id: String { provider.rawValue }
}

enum PrimaryCapsuleFrameKind: Equatable {
    case shortcut
    case usage
}

struct PrimaryCapsuleFrame: Equatable {
    let kind: PrimaryCapsuleFrameKind
    let iconName: String
    let leadingText: String
    let bodyText: String
    let trailingText: String
    let usageProgress: Double?
    let resetText: String?
    let secondaryText: String
    let secondaryUsageProgress: Double?
    let secondaryTrailingText: String

    init(
        kind: PrimaryCapsuleFrameKind,
        iconName: String,
        leadingText: String,
        bodyText: String,
        trailingText: String,
        usageProgress: Double?,
        resetText: String?,
        secondaryText: String = "",
        secondaryUsageProgress: Double? = nil,
        secondaryTrailingText: String = ""
    ) {
        self.kind = kind
        self.iconName = iconName
        self.leadingText = leadingText
        self.bodyText = bodyText
        self.trailingText = trailingText
        self.usageProgress = usageProgress
        self.resetText = resetText
        self.secondaryText = secondaryText
        self.secondaryUsageProgress = secondaryUsageProgress
        self.secondaryTrailingText = secondaryTrailingText
    }

    static func shortcut(leading: String, body: String) -> PrimaryCapsuleFrame {
        PrimaryCapsuleFrame(
            kind: .shortcut,
            iconName: "command",
            leadingText: leading,
            bodyText: body,
            trailingText: "Shortcuts",
            usageProgress: nil,
            resetText: nil
        )
    }
}

enum UsageSummaryFormatter {
    static let shortcutTips: [(leading: String, body: String)] = [
        ("Tip", "Cmd+1..4 switch layout"),
        ("Tip", "hjkl/arrows navigate, Return or i enter terminal"),
        ("Tip", "Cmd+Esc leave terminal / toggle sidebar"),
        ("Tip", "Double-Ctrl open island command"),
        ("Tip", "Cmd+B toggle sidebar"),
        ("Tip", "Cmd+D split horizontally"),
        ("Tip", "Cmd+Shift+D split vertically"),
        ("Tip", "Cmd+Option+Arrow move focus"),
        ("Tip", "Cmd+Ctrl+Arrow resize split"),
        ("Tip", "Cmd+Shift+F show diff"),
    ]

    static func rotationFrames(claude: UsageSnapshot, codex: UsageSnapshot, now: Date = Date()) -> [PrimaryCapsuleFrame] {
        shortcutTips.map { PrimaryCapsuleFrame.shortcut(leading: $0.leading, body: $0.body) }
            + [formatUsageFrame(claude, now: now), formatUsageFrame(codex, now: now)]
    }

    /// Readouts for every provider that currently has rate-limit data. A
    /// provider with nothing to report is dropped rather than rendered as
    /// "--" — the island only shows quota it actually knows.
    static func readouts(claude: UsageSnapshot, codex: UsageSnapshot, now: Date = Date()) -> [UsageReadout] {
        [readout(for: claude, now: now), readout(for: codex, now: now)].compactMap { $0 }
    }

    static func readout(for snapshot: UsageSnapshot, now: Date = Date()) -> UsageReadout? {
        var segments: [UsageReadoutSegment] = []
        if let window = snapshot.rateLimit {
            segments.append(segment(label: window.label ?? "5h", window: window, now: now))
        }
        if let window = snapshot.weeklyRateLimit {
            segments.append(segment(label: window.label ?? "7d", window: window, now: now))
        }
        guard !segments.isEmpty else { return nil }
        return UsageReadout(
            provider: snapshot.provider,
            logoName: snapshot.provider == .claude ? "ClaudeLogo" : "OpenAILogo",
            segments: segments
        )
    }

    private static func segment(label: String, window: UsageRateLimitWindow, now: Date) -> UsageReadoutSegment {
        UsageReadoutSegment(
            label: label,
            percentText: "\(window.usedPercent)%",
            severity: .init(usedPercent: window.usedPercent),
            resetText: window.resetsAt.flatMap { compactResetText(until: $0, now: now) }
        )
    }

    static func formatUsageFrame(_ snapshot: UsageSnapshot, now: Date = Date()) -> PrimaryCapsuleFrame {
        if snapshot.provider == .claude {
            return formatClaudeUsageFrame(snapshot, now: now)
        }

        let remaining = snapshot.rateLimit.map { "\($0.remainingPercent)%" } ?? "--"
        let today = snapshot.todayTokens.map(compactTokenCount) ?? "--"
        let resetText = snapshot.rateLimit?.resetsAt.flatMap { compactResetText(until: $0, now: now) }
        return PrimaryCapsuleFrame(
            kind: .usage,
            iconName: snapshot.provider == .claude ? "sparkles" : "terminal",
            leadingText: snapshot.provider.displayName,
            bodyText: "\(remaining) left",
            trailingText: "Today \(today)",
            usageProgress: snapshot.rateLimit?.progress,
            resetText: resetText
        )
    }

    private static func formatClaudeUsageFrame(_ snapshot: UsageSnapshot, now: Date) -> PrimaryCapsuleFrame {
        let sessionStatus = usageStatus(for: snapshot.rateLimit, now: now)
        let weeklyStatus = usageStatus(for: snapshot.weeklyRateLimit, now: now)
        return PrimaryCapsuleFrame(
            kind: .usage,
            iconName: "sparkles",
            leadingText: snapshot.provider.displayName,
            bodyText: "Current session:",
            trailingText: sessionStatus,
            usageProgress: snapshot.rateLimit?.progress,
            resetText: nil,
            secondaryText: "Weekly limits:",
            secondaryUsageProgress: snapshot.weeklyRateLimit?.progress,
            secondaryTrailingText: weeklyStatus
        )
    }

    private static func usageStatus(for window: UsageRateLimitWindow?, now: Date) -> String {
        guard let window else { return "--" }
        var text = "\(window.usedPercent)%"
        if let reset = window.resetsAt.flatMap({ compactResetText(until: $0, now: now) }) {
            text += ", Resets \(reset)"
        }
        return text
    }

    static func compactTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    private static func compactResetText(until resetsAt: Date, now: Date) -> String? {
        let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
        guard seconds > 0 else { return nil }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(max(1, minutes))m"
    }
}
