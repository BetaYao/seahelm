import Foundation

/// A decoded OSC 9;4 (ConEmu-style) progress report.
///
/// `GhosttyBridge` encodes libghostty's `GHOSTTY_ACTION_PROGRESS_REPORT` into the
/// wire string `"<state>;<percent>"` on `Station.oscProgress`, where percent is
/// empty when the terminal reported none. This is the one decoder for that string
/// — the manifest engine matches it as raw text, so anything that wants the
/// *meaning* (the pane progress bar) goes through here instead of re-parsing.
struct OSCProgress: Equatable {
    /// Mirrors `ghostty_action_progress_report_state_e`.
    enum State: Int {
        case remove = 0        // progress finished/cleared — show nothing
        case set = 1           // determinate, `percent` is meaningful
        case error = 2         // failed; percent may still be present
        case indeterminate = 3 // running, no percentage available
        case pause = 4         // paused at `percent`
    }

    let state: State
    /// 0…100, or nil when the terminal reported no percentage (`-1` on the wire).
    let percent: Int?

    /// Decode `"<state>;<percent>"`. Returns nil for an empty/garbled value so
    /// callers can treat "never reported" and "unparseable" identically.
    init?(wire: String) {
        guard !wire.isEmpty else { return nil }
        let parts = wire.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawState = Int(parts.first ?? ""), let state = State(rawValue: rawState) else {
            return nil
        }
        self.state = state
        if parts.count > 1, let value = Int(parts[1]), (0...100).contains(value) {
            percent = value
        } else {
            percent = nil
        }
    }

    /// Something worth drawing. `remove` is the terminal saying "done, clear it".
    var isActive: Bool { state != .remove }

    /// A determinate fraction to fill, or nil when the bar should run
    /// indeterminate (no percentage reported, or explicitly indeterminate).
    var fraction: Double? {
        guard state != .indeterminate, let percent else { return nil }
        return Double(percent) / 100.0
    }
}
