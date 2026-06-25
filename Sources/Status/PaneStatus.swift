import Foundation

struct PaneStatus {
    let paneIndex: Int        // 1-based, follows SplitTree leaf order
    let terminalID: String    // Station.id
    var status: SailorStatus
    var lastMessage: String
    var lastUserPrompt: String
    var lastUpdated: Date     // When status or message last changed
}

struct WorktreeStatus {
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

    var highestPriority: SailorStatus {
        SailorStatus.highestPriority(panes.map(\.status))
    }
}
