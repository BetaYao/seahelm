import Foundation

/// seahelm-core's panes and cards read into the app's types
/// (docs/app-reads-core.md): a pane's `info` (`events::pane_detail`), and
/// cards. Pure.
enum CoreDecode {
    // MARK: the pane

    /// Lay a pane's `info` over the app's snapshot. Identity, worktree,
    /// project and branch stay the app's: the app owns its layout.
    static func apply(_ info: [String: Any], to p: inout PaneInfo) {
        // Only the keys given: `pane.unseen_changed` sends one.
        func has(_ k: String) -> Bool { info.keys.contains(k) }
        if let s = status(info["status"]) { p.status = s }
        if let t = agentType(info["agent_type"]), t != .unknown { p.agentType = t }
        if let v = info["last_message"] as? String { p.lastMessage = v }
        if let v = info["last_assistant_message"] as? String { p.lastAssistantMessage = v }
        if has("last_assistant_message_at") { p.lastAssistantMessageAt = date(info["last_assistant_message_at"]) }
        if let v = info["last_user_prompt"] as? String { p.lastUserPrompt = v }
        if has("last_user_prompt_at") { p.lastUserPromptAt = date(info["last_user_prompt_at"]) }
        if has("command_line") { p.commandLine = info["command_line"] as? String }
        if let v = info["round_duration"] as? Double { p.roundDuration = v }
        if has("tasks") { p.tasks = (info["tasks"] as? [[String: Any]] ?? []).compactMap(task) }
        if has("activity_events") {
            p.activityEvents = (info["activity_events"] as? [[String: Any]] ?? []).compactMap(activity)
        }
        if has("scan_status") { p.scanStatus = status(info["scan_status"]) ?? .unknown }
        if has("hook_status") { p.hookStatus = status(info["hook_status"]) ?? .unknown }
        if has("program_status") { p.programStatus = status(info["program_status"]) ?? .unknown }
        if has("program_state") { p.programState = programState(info["program_state"] as? String) }
        if let v = info["background_busy"] as? Bool { p.backgroundBusy = v }
        if let v = info["unseen"] as? Bool { p.unseenCompletion = v }
    }

    // MARK: pieces

    static func status(_ v: Any?) -> AgentStatus? { (v as? String).flatMap(AgentStatus.init(rawValue:)) }
    static func agentType(_ v: Any?) -> AgentType? { (v as? String).flatMap(AgentType.init(rawValue:)) }

    static func date(_ v: Any?) -> Date? {
        (v as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    static func activity(_ v: Any?) -> ActivityEvent? {
        guard let d = v as? [String: Any], let tool = d["tool"] as? String else { return nil }
        return ActivityEvent(tool: tool, detail: d["detail"] as? String ?? "",
                             isError: d["is_error"] as? Bool ?? false,
                             timestamp: date(d["timestamp"]) ?? Date())
    }

    static func task(_ d: [String: Any]) -> TaskItem? {
        guard let id = d["id"] as? String else { return nil }
        return TaskItem(id: id, subject: d["subject"] as? String ?? "",
                        status: TaskItemStatus(rawValue: d["status"] as? String ?? "") ?? .pending)
    }

    static func flags(_ v: Any?) -> QuestionFlags {
        let d = v as? [String: Any] ?? [:]
        var f = QuestionFlags()
        f.multiSelect = d["multi_select"] as? Bool ?? false
        f.reviewAfter = d["review_after"] as? Bool ?? false
        f.checked = Set(d["checked"] as? [Int] ?? [])
        f.cursor = d["cursor"] as? Int ?? 0
        f.askId = d["ask_id"] as? String ?? ""
        return f
    }

    static func questionSpec(_ d: [String: Any]) -> QuestionSpec {
        QuestionSpec(prompt: d["prompt"] as? String ?? "", options: d["options"] as? [String] ?? [],
                     flags: flags(d["flags"]))
    }

    static func programState(_ s: String?) -> ProgramStatusReport.State? {
        switch s {
        case "idle": return .idle
        case "working": return .working
        case "done": return .done
        case "blocked": return .blocked
        case "error": return .error
        default: return nil
        }
    }

}
