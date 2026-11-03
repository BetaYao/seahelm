import Foundation

/// When a pane's finished turn becomes "unseen", and when it stops being.
/// See `PaneInfo.unseenCompletion`; the window decides what counts as looking.
enum UnseenCompletion {
    /// The "group by status" heading for idle rows with an unread finish.
    static let groupTitle = "Finished"
    /// A turn ending: the agent was working and is now at rest.
    static func marks(oldStatus: AgentStatus, newStatus: AgentStatus) -> Bool {
        oldStatus == .running && newStatus == .idle
    }

    /// Anything the agent does next supersedes the unread result: it is working
    /// again, or it wants something (which says so louder), or it is gone.
    static func clears(newStatus: AgentStatus) -> Bool {
        switch newStatus {
        case .running, .waiting, .error, .exited: return true
        case .idle, .unknown: return false
        }
    }
}
