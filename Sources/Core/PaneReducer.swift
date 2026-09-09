import Foundation

/// Pure status reducer: old snapshot + applied inputs → new snapshot + change delta.
/// No IO, no singletons. Mirrors the field-application logic formerly inline in
/// AgentRegistry.updateStatus so it can be unit-tested and reused by ingest().
enum PaneReducer {
    static func apply(to info: PaneInfo,
                      status: AgentStatus,
                      lastMessage: String,
                      roundDuration: TimeInterval,
                      tasks: [TaskItem],
                      lastUserPrompt: String,
                      now: Date = Date()) -> (info: PaneInfo, changed: Bool, previousStatus: AgentStatus) {
        var next = info
        let previousStatus = info.status
        let changed = info.status != status
            || info.lastMessage != lastMessage
            || info.tasks.count != tasks.count
        next.status = status
        next.lastMessage = lastMessage
        // Only on a *change*: this runs on every poll with the prompt re-passed
        // unchanged, and stamping it each time would leave the prompt forever
        // newer than the answer to it.
        if !lastUserPrompt.isEmpty, lastUserPrompt != next.lastUserPrompt {
            next.lastUserPrompt = lastUserPrompt
            next.lastUserPromptAt = now
        }
        next.roundDuration = roundDuration
        next.tasks = tasks
        return (next, changed, previousStatus)
    }
}
