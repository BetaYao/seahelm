import Foundation

/// Pure status reducer: old snapshot + applied inputs → new snapshot + change delta.
/// No IO, no singletons. Mirrors the field-application logic formerly inline in
/// ShipLog.updateStatus so it can be unit-tested and reused by ingest().
enum SailorReducer {
    static func apply(to info: SailorInfo,
                      status: SailorStatus,
                      lastMessage: String,
                      roundDuration: TimeInterval,
                      tasks: [TaskItem],
                      lastUserPrompt: String) -> (info: SailorInfo, changed: Bool, previousStatus: SailorStatus) {
        var next = info
        let previousStatus = info.status
        let changed = info.status != status
            || info.lastMessage != lastMessage
            || info.tasks.count != tasks.count
        next.status = status
        next.lastMessage = lastMessage
        if !lastUserPrompt.isEmpty {
            next.lastUserPrompt = lastUserPrompt
        }
        next.roundDuration = roundDuration
        next.tasks = tasks
        return (next, changed, previousStatus)
    }
}
