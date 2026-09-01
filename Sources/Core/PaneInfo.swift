import Foundation

struct PaneInfo {
    let id: String                     // terminal ID (Station.id)
    let worktreePath: String           // associated worktree path
    var agentType: AgentType           // detected from terminal content
    let project: String                // repo display name
    let branch: String                 // git branch
    var status: AgentStatus            // current status
    var lastMessage: String            // latest message (may be a scanned command line)
    /// The agent's final prose (Stop hook `last_assistant_message`). Set only by
    /// noteAssistantMessage and never overwritten by screen scans, so suggestion
    /// cards can show the real explanation rather than the `seahelm-suggest …` line.
    var lastAssistantMessage: String = ""
    var lastUserPrompt: String = ""    // most recent user prompt text
    var commandLine: String?           // current command from OSC 133 or text matching
    var roundDuration: TimeInterval    // seconds in current running round
    let startedAt: Date?               // for computing totalDuration live
    weak var station: Station? // weak ref, MainWindowController owns
    var channel: AgentChannel?         // communication channel (strong ref, AgentRegistry owns)
    var taskProgress: TaskProgress     // current task progress
    var tasks: [TaskItem] = []          // webhook-tracked task items
    var activityEvents: [ActivityEvent] = []
    var scanStatus: AgentStatus = .unknown   // latest screen-scan observation (component)
    var hookStatus: AgentStatus = .unknown   // webhook-accumulated inference (component)
    /// The session has background work of its own — a shell it launched, a monitor
    /// it watches. A separate axis from `status` on purpose: the agent can be idle
    /// at an empty prompt while this is true, and folding it into the status
    /// pinned such a pane on `running` for the life of the monitor, which cost it
    /// every completion edge (and so every notification) it would have produced.
    var backgroundBusy: Bool = false

    /// What the dashboard draws. Background work still reads as busy — a worktree
    /// watching CI is not "done" — while `status` stays the honest answer to
    /// "what is the agent doing", which is what edges and notifications ride on.
    var displayStatus: AgentStatus {
        (status == .idle && backgroundBusy) ? .running : status
    }

    /// Total duration computed live from startedAt
    var totalDuration: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }
}

extension PaneInfo {
    /// A copy of this pane re-attributed to a different worktree, keeping every
    /// live field.
    ///
    /// `worktreePath`/`branch`/`project` are `let` on purpose — a pane's identity
    /// is not meant to drift — so a move rebuilds the struct instead of mutating
    /// it. Anything added to `PaneInfo` with a default value must be carried here
    /// too, or a moved pane silently loses it.
    func rehomed(to newWorktreePath: String, branch newBranch: String, project newProject: String) -> PaneInfo {
        var copy = PaneInfo(
            id: id,
            worktreePath: newWorktreePath,
            agentType: agentType,
            project: newProject,
            branch: newBranch,
            status: status,
            lastMessage: lastMessage,
            commandLine: commandLine,
            roundDuration: roundDuration,
            startedAt: startedAt,
            station: station,
            channel: channel,
            taskProgress: taskProgress
        )
        copy.lastAssistantMessage = lastAssistantMessage
        copy.lastUserPrompt = lastUserPrompt
        copy.tasks = tasks
        copy.activityEvents = activityEvents
        copy.scanStatus = scanStatus
        copy.hookStatus = hookStatus
        copy.backgroundBusy = backgroundBusy
        return copy
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

struct TaskItem: Equatable {
    let id: String
    var subject: String
    var status: TaskItemStatus
}
