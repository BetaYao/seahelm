import Foundation

/// seahelm-core's pane events, read back into the app's own types
/// (docs/app-reads-core.md). The core sends each decided outcome with the
/// whole pane (`info`, `events::pane_detail`) and the event it decided on
/// (`event`, core-types' serde shape: `source` tagged by `type`, `kind` by
/// `kind`). Pure.
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

    // MARK: the event

    static func source(_ v: Any?) -> EventSource {
        let d = v as? [String: Any] ?? [:]
        switch d["type"] as? String {
        case "hook": return .hook(d["name"] as? String ?? "")
        case "osc7501": return .osc7501
        default: return .scan
        }
    }

    static func kind(_ v: Any?) -> NormalizedEventKind? {
        guard let d = v as? [String: Any], let kind = d["kind"] as? String else { return nil }
        let text = d["text"] as? String ?? ""
        switch kind {
        case "session_started": return .sessionStarted(label: d["label"] as? String ?? "")
        case "user_prompt": return .userPrompt(text)
        case "tool_use":
            guard let a = activity(d["activity"]) else { return nil }
            return .toolUse(a)
        case "awaiting_input": return .awaitingInput(text)
        case "agent_stopped": return .agentStopped(success: d["success"] as? Bool ?? true)
        case "notification": return .notification(level: d["level"] as? String ?? "", text: text)
        case "task_update": return .taskUpdate((d["tasks"] as? [[String: Any]] ?? []).compactMap(task))
        case "suggest": return .suggest(options: d["options"] as? [String] ?? [])
        case "question":
            return .question(prompt: d["prompt"] as? String ?? "",
                             options: d["options"] as? [String] ?? [],
                             followups: (d["followups"] as? [[String: Any]] ?? []).map(questionSpec),
                             flags: flags(d["flags"]))
        case "screen_observed":
            return .screenObserved(status: status(d["status"]) ?? .unknown,
                                   message: d["message"] as? String ?? "",
                                   activity: (d["activity"] as? [[String: Any]] ?? []).compactMap(activity),
                                   commandLine: d["command_line"] as? String,
                                   agentType: agentType(d["agent_type"]) ?? .unknown,
                                   roundDuration: d["round_duration"] as? Double ?? 0,
                                   tasks: (d["tasks"] as? [[String: Any]] ?? []).compactMap(task),
                                   backgroundBusy: d["background_busy"] as? Bool ?? false)
        case "program_status":
            return .programStatus(programRecord(d["record"]))
        default:
            return nil
        }
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

    static func programRecord(_ v: Any?) -> ProgramStatusRecord? {
        guard let d = v as? [String: Any], let state = programState(d["state"] as? String) else { return nil }
        let kind: ProgramStatusReport.Kind? = switch d["kind"] as? String {
        case "permission": .permission
        case "question": .question
        case "auth": .auth
        default: nil
        }
        let app = d["app"] as? String ?? ""
        let report = ProgramStatusReport(state: state, kind: kind, progress: d["progress"] as? Int,
                                         app: app, title: d["title"] as? String ?? "", msg: d["msg"] as? String ?? "")
        return ProgramStatusRecord(report: report, app: app, stamp: 0)
    }
}
