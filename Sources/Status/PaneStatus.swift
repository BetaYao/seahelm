import Foundation

struct PaneStatus: Equatable {
    let paneIndex: Int        // 1-based, follows SplitTree leaf order
    let terminalID: String    // Station.id
    var status: SailorStatus
    var lastMessage: String
    var lastUserPrompt: String
    var lastUpdated: Date     // When status or message last changed
    /// When `status` last changed — not advanced by message-only updates. The
    /// worktree rollup picks the pane that changed most recently, so a pane
    /// merely printing output must not take the badge from one that just went
    /// waiting.
    var statusChangedAt: Date
    var agentType: SailorType = .unknown
}

struct WorktreeStatus: Equatable {
    let worktreePath: String
    var panes: [PaneStatus]           // Ordered by SplitTree leaf position
    var mostRecentPaneIndex: Int      // Pane whose lastMessage is displayed
    var mostRecentMessage: String     // That pane's lastMessage
    var mostRecentUserPrompt: String  // That pane's lastUserPrompt

    var statuses: [SailorStatus] {
        panes.map(\.status)
    }

    var hasUrgent: Bool {
        panes.contains { $0.status.isUrgent }
    }

    /// The pane that speaks for the worktree: whichever changed status most
    /// recently. Status AND message come from this same pane so the badge and
    /// the text can never disagree.
    ///
    /// This used to be a priority ranking (waiting > error > … , agents over
    /// shell tasks). Recency is the simpler rule and matches what the row is
    /// read as — "what is this worktree doing now" — at the cost that a pane
    /// which went waiting an hour ago no longer holds the badge against a pane
    /// that just started running.
    var representative: PaneStatus? {
        panes.max { $0.statusChangedAt < $1.statusChangedAt }
    }

    var rolledUpStatus: SailorStatus {
        representative?.status ?? .unknown
    }
}
