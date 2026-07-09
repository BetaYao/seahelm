import Foundation

enum WebhookEventType: String {
    case sessionStart = "session_start"
    case toolUseStart = "tool_use_start"
    case toolUseEnd = "tool_use_end"
    case agentStop = "agent_stop"
    case notification = "notification"
    case error = "error"
    case prompt = "prompt"
    case worktreeCreate = "worktree_create"
    case userPrompt = "user_prompt"
    case toolUseFailed = "tool_use_failed"
    case stopFailure = "stop_failure"
    case subagentStart = "subagent_start"
    case subagentStop = "subagent_stop"
    case cwdChanged = "cwd_changed"
    case suggest = "suggest"

    func agentStatus(data: [String: Any]?) -> SailorStatus {
        switch self {
        case .sessionStart, .toolUseStart, .toolUseEnd, .subagentStart, .subagentStop, .userPrompt, .toolUseFailed:
            // A subagent finishing does NOT mean the main agent is idle — it usually resumes.
            return .running
        case .agentStop:
            return .idle
        case .error, .stopFailure:
            return .error
        case .prompt:
            return .waiting
        case .worktreeCreate, .cwdChanged:
            return .running
        case .suggest:
            return .unknown
        case .notification:
            let level = data?["level"] as? String
            switch level {
            case "error": return .error
            case "warning": return .waiting
            default: return .unknown
            }
        }
    }

    /// Map Claude Code hook_event_name to generic event type
    static func fromClaudeCode(_ hookEventName: String) -> WebhookEventType? {
        switch hookEventName {
        case "SessionStart": return .sessionStart
        case "PreToolUse": return .toolUseStart
        case "PostToolUse": return .toolUseEnd
        case "Stop": return .agentStop
        case "SubagentStop": return .subagentStop
        case "Notification": return .notification
        case "WorktreeCreate": return .worktreeCreate
        case "UserPromptSubmit": return .userPrompt
        case "PostToolUseFailure": return .toolUseFailed
        case "StopFailure": return .stopFailure
        case "SubagentStart": return .subagentStart
        case "CwdChanged": return .cwdChanged
        default: return nil
        }
    }
}

struct WebhookEvent {
    let source: String
    let sessionId: String
    /// Absolute path to the agent's native session/transcript file, when the
    /// payload carries one (Claude's `transcript_path`, or a generic payload's
    /// `session_path`). Used to build a path-kind `AgentSessionRef` for agents
    /// that resume by path. Nil when absent.
    let sessionPath: String?
    let event: WebhookEventType
    let cwd: String
    let timestamp: String?
    let data: [String: Any]?
    /// Stable pane id (SEAHELM_PANE_ID) the hook ran under, injected by the
    /// seahelm-hook bridge. Attributes the event to an exact pane. Nil when the
    /// hook predates the injection or ran outside a seahelm pane.
    let paneId: String?

    /// Explicit memberwise init with `sessionPath`/`paneId` defaulted so existing
    /// call sites (which predate the fields) keep compiling.
    init(
        source: String,
        sessionId: String,
        sessionPath: String? = nil,
        event: WebhookEventType,
        cwd: String,
        timestamp: String?,
        data: [String: Any]?,
        paneId: String? = nil
    ) {
        self.source = source
        self.sessionId = sessionId
        self.sessionPath = sessionPath
        self.event = event
        self.cwd = cwd
        self.timestamp = timestamp
        self.data = data
        self.paneId = paneId
    }

    /// Parse from JSON data. Supports generic protocol and native hook payloads.
    static func parse(from jsonData: Data) throws -> WebhookEvent {
        guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw WebhookEventError.invalidJSON
        }

        // Detect format: native hook payloads have "hook_event_name", generic payloads have "event"
        if let hookEventName = json["hook_event_name"] as? String {
            return try parseNativeHook(json: json, hookEventName: hookEventName)
        } else {
            return try parseGeneric(json: json)
        }
    }

    private static func parseGeneric(json: [String: Any]) throws -> WebhookEvent {
        guard let source = json["source"] as? String,
              let sessionId = json["session_id"] as? String,
              let eventRaw = json["event"] as? String,
              let cwd = json["cwd"] as? String else {
            throw WebhookEventError.missingRequiredField
        }
        guard let event = WebhookEventType(rawValue: eventRaw) else {
            throw WebhookEventError.unknownEventType(eventRaw)
        }
        return WebhookEvent(
            source: source,
            sessionId: sessionId,
            sessionPath: json["session_path"] as? String,
            event: event,
            cwd: cwd,
            timestamp: json["timestamp"] as? String,
            data: json["data"] as? [String: Any],
            paneId: json["seahelm_pane_id"] as? String
        )
    }

    private static func parseNativeHook(json: [String: Any], hookEventName: String) throws -> WebhookEvent {
        guard let sessionId = json["session_id"] as? String,
              let cwd = json["cwd"] as? String else {
            throw WebhookEventError.missingRequiredField
        }
        guard let event = WebhookEventType.fromClaudeCode(hookEventName) else {
            throw WebhookEventError.unknownEventType(hookEventName)
        }
        let source = inferNativeHookSource(from: json, hookEventName: hookEventName)

        // Collect remaining fields as data
        var data: [String: Any] = [:]
        let reservedKeys: Set<String> = ["hook_event_name", "session_id", "cwd", "transcript_path", "permission_mode", "seahelm_pane_id"]
        for (key, value) in json where !reservedKeys.contains(key) {
            data[key] = value
        }

        return WebhookEvent(
            source: source,
            sessionId: sessionId,
            // Claude Code's `transcript_path` is the session's on-disk file.
            sessionPath: json["transcript_path"] as? String ?? json["session_path"] as? String,
            event: event,
            cwd: cwd,
            timestamp: nil,
            data: data.isEmpty ? nil : data,
            paneId: json["seahelm_pane_id"] as? String
        )
    }

    /// Inference based on observed payload differences:
    /// Codex hook payloads commonly include extra execution metadata such as turn_id/call_id/tool_kind/model.
    /// Claude Code-only hook events are treated as Claude immediately.
    private static func inferNativeHookSource(from json: [String: Any], hookEventName: String) -> String {
        switch hookEventName {
        case "Notification", "WorktreeCreate", "PostToolUseFailure", "StopFailure", "SubagentStart", "SubagentStop", "CwdChanged":
            return "claude-code"
        default:
            break
        }

        let codexSpecificKeys: Set<String> = [
            "turn_id",
            "call_id",
            "tool_kind",
            "duration_ms",
            "output_preview",
            "model",
            "agent_id",
            "agent_type",
        ]

        if !codexSpecificKeys.isDisjoint(with: Set(json.keys)) {
            return "codex"
        }

        return "claude-code"
    }
}

enum WebhookEventError: Error {
    case invalidJSON
    case missingRequiredField
    case unknownEventType(String)
}
