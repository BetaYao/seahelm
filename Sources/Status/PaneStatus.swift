import Foundation

struct PaneStatus: Equatable {
    let paneIndex: Int        // 1-based, follows SplitTree leaf order
    let terminalID: String    // Station.id
    var status: SailorStatus
    var lastMessage: String
    var lastUserPrompt: String
    var lastUpdated: Date     // When status or message last changed
    var agentType: SailorType = .unknown

    /// Rollup rank: an AI agent's state outranks a shell task's at the same
    /// status priority, so a long-running `npm run dev` never masks a blocked
    /// agent in the same worktree.
    var rollupRank: (UInt8, UInt8) {
        (agentType.isAIAgent ? 1 : 0, status.priority)
    }
}

struct CabinStatus: Equatable {
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

    /// The pane that speaks for the worktree: highest rollup rank (AI agents win
    /// ties over shell tasks). Status AND message come from this same pane so the
    /// badge and the text can never disagree.
    var representative: PaneStatus? {
        panes.max { $0.rollupRank < $1.rollupRank }
    }

    var highestPriority: SailorStatus {
        representative?.status ?? .unknown
    }
}
