import Foundation

struct AgentInfo {
    let id: String                     // terminal ID (TerminalSurface.id)
    let worktreePath: String           // associated worktree path
    var agentType: AgentType           // detected from terminal content
    let project: String                // repo display name
    let branch: String                 // git branch
    var status: AgentStatus            // current status
    var lastMessage: String            // latest message
    var lastUserPrompt: String = ""    // most recent user prompt text
    var commandLine: String?           // current command from OSC 133 or text matching
    var roundDuration: TimeInterval    // seconds in current running round
    let startedAt: Date?               // for computing totalDuration live
    weak var surface: TerminalSurface? // weak ref, MainWindowController owns
    var channel: AgentChannel?         // communication channel (strong ref, AgentHead owns)
    var taskProgress: TaskProgress     // current task progress
    var tasks: [TaskItem] = []          // webhook-tracked task items
    var activityEvents: [ActivityEvent] = []

    /// Total duration computed live from startedAt
    var totalDuration: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }
}

/// Tracks an agent's task progress (how many tasks completed out of total)
struct TaskProgress {
    var totalTasks: Int = 0            // total tasks in current session
    var completedTasks: Int = 0        // tasks completed so far
    var currentTask: String?           // description of current task

    var isActive: Bool { totalTasks > 0 }

    var summary: String {
        guard isActive else { return "" }
        return "\(completedTasks)/\(totalTasks)"
    }

    var percentage: Double {
        guard totalTasks > 0 else { return 0 }
        return Double(completedTasks) / Double(totalTasks)
    }
}

enum TaskItemStatus: String {
    case pending
    case inProgress = "in_progress"
    case completed
}

struct TaskItem {
    let id: String
    var subject: String
    var status: TaskItemStatus
}
