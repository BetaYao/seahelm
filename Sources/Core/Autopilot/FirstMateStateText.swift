import AppKit

/// First Mate's state in words and a tone, for every surface that shows it:
/// the island, `autopilot.state` for seahelm-web. (Moved out of the fleet
/// column's dock, which is gone: First Mate lives in the island.)
enum FirstMateStateText {
    enum Tone: Equatable { case quiet, watching, working, wantsYou }

    static func describe(_ activity: FirstMateLink.State.Activity) -> (String, NSColor) {
        switch activity {
        case .off: return ("off", SemanticColors.subtle)
        case .starting: return ("starting", SemanticColors.subtle)
        case .idle: return ("watching", SemanticColors.accent)
        case .thinking: return ("working", SemanticColors.running)
        case .needsYou: return ("needs you", SemanticColors.attention)
        case .paused: return ("paused", SemanticColors.subtle)
        }
    }

    static func tone(_ state: FirstMateLink.State) -> Tone {
        if state.activity == .needsYou || (state.pendingApprovals > 0 && state.activity != .off) { return .wantsYou }
        switch state.activity {
        case .off, .paused, .starting: return .quiet
        case .thinking: return .working
        case .idle, .needsYou: return .watching
        }
    }

    /// What is true now: the tooltip always, the second line when it wants you.
    static func detailLine(_ state: FirstMateLink.State, now: Date) -> String {
        let queued = state.queued > 0 ? "\(state.queued) queued · " : ""
        switch state.activity {
        case .off: return "Off — click to set it up"
        case .starting: return "Starting its session…"
        case .paused: return queued.isEmpty ? "Paused — events wait until you resume" : "Paused · \(queued)waiting to resume"
        case .needsYou: return "Waiting for your answer in its terminal"
        case .thinking:
            if state.pendingApprovals > 0 { return "\(state.pendingApprovals) waiting for your approval" }
            let doing = state.doing.trimmingCharacters(in: .whitespacesAndNewlines)
            return queued + (doing.isEmpty ? "Working…" : doing)
        case .idle:
            if state.pendingApprovals > 0 {
                return "\(state.pendingApprovals) waiting for your approval"
            }
            if let at = state.latestAt, now.timeIntervalSince(at) < 6 * 3600, !state.latest.isEmpty {
                return queued + Self.ago(at, now: now) + " · " + state.latest
            }
            let projects = state.watching == 1 ? "1 project" : "\(state.watching) projects"
            return queued + "\(projects) · CI & merges"
        }
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}
