//! What a hook payload says: which agent, which session, which lifecycle
//! event, where.
//!
//! Three payload shapes reach the `hook` method, and `parse` tells them
//! apart:
//!
//! - **Generic** (`event`, `source`, `session_id`, `cwd`, `data`): what the
//!   OpenCode and Pi plugins and `seahelm-suggest` send.
//! - **Native Claude/Codex** (`hook_event_name` in PascalCase, every other
//!   field flat beside it): what the `seahelm-hook` shim forwards verbatim.
//! - **Cursor** (`hook_event_name` in camelCase, `conversation_id`,
//!   `workspace_roots`): shaped nothing like Claude's, so it has its own
//!   adapter rather than failing Claude's required fields.
//!
//! The shim splices in `seahelm_source` (who invoked it) and
//! `seahelm_pane_id`; the declared source always beats key sniffing.

use seahelm_core_types::AgentStatus;
use serde_json::Value;

use crate::Map;

/// Every lifecycle event seahelm understands, by its wire name.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum WebhookEventType {
    SessionStart,
    ToolUseStart,
    ToolUseEnd,
    AgentStop,
    Notification,
    Error,
    Prompt,
    WorktreeCreate,
    UserPrompt,
    ToolUseFailed,
    StopFailure,
    SubagentStart,
    SubagentStop,
    CwdChanged,
    Suggest,
    /// Cursor `afterAgentResponse`: the turn's final assistant prose (in
    /// `text`). Not a status signal; it is where Cursor's inline
    /// `::seahelm-suggest::` line is harvested from.
    AssistantResponse,
}

impl WebhookEventType {
    pub const ALL: [WebhookEventType; 16] = [
        Self::SessionStart,
        Self::ToolUseStart,
        Self::ToolUseEnd,
        Self::AgentStop,
        Self::Notification,
        Self::Error,
        Self::Prompt,
        Self::WorktreeCreate,
        Self::UserPrompt,
        Self::ToolUseFailed,
        Self::StopFailure,
        Self::SubagentStart,
        Self::SubagentStop,
        Self::CwdChanged,
        Self::Suggest,
        Self::AssistantResponse,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::SessionStart => "session_start",
            Self::ToolUseStart => "tool_use_start",
            Self::ToolUseEnd => "tool_use_end",
            Self::AgentStop => "agent_stop",
            Self::Notification => "notification",
            Self::Error => "error",
            Self::Prompt => "prompt",
            Self::WorktreeCreate => "worktree_create",
            Self::UserPrompt => "user_prompt",
            Self::ToolUseFailed => "tool_use_failed",
            Self::StopFailure => "stop_failure",
            Self::SubagentStart => "subagent_start",
            Self::SubagentStop => "subagent_stop",
            Self::CwdChanged => "cwd_changed",
            Self::Suggest => "suggest",
            Self::AssistantResponse => "assistant_response",
        }
    }

    pub fn from_wire(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|t| t.as_str() == s)
    }

    /// The status this event implies on its own. A subagent finishing does
    /// not make the main agent idle — it usually resumes — so it reads as
    /// running.
    pub fn agent_status(&self, data: &Map) -> AgentStatus {
        match self {
            Self::SessionStart
            | Self::ToolUseStart
            | Self::ToolUseEnd
            | Self::SubagentStart
            | Self::SubagentStop
            | Self::UserPrompt
            | Self::ToolUseFailed
            | Self::WorktreeCreate
            | Self::CwdChanged => AgentStatus::Running,
            Self::AgentStop => AgentStatus::Idle,
            Self::Error | Self::StopFailure => AgentStatus::Error,
            Self::Prompt => AgentStatus::Waiting,
            Self::Suggest | Self::AssistantResponse => AgentStatus::Unknown,
            Self::Notification => match data.get("level").and_then(Value::as_str) {
                Some("error") => AgentStatus::Error,
                Some("warning") => AgentStatus::Waiting,
                _ => AgentStatus::Unknown,
            },
        }
    }

    /// Claude Code's (and Codex's) `hook_event_name`.
    pub fn from_claude_code(name: &str) -> Option<Self> {
        Some(match name {
            "SessionStart" => Self::SessionStart,
            "PreToolUse" => Self::ToolUseStart,
            "PostToolUse" => Self::ToolUseEnd,
            "Stop" => Self::AgentStop,
            "SubagentStop" => Self::SubagentStop,
            "Notification" => Self::Notification,
            "WorktreeCreate" => Self::WorktreeCreate,
            "UserPromptSubmit" => Self::UserPrompt,
            "PostToolUseFailure" => Self::ToolUseFailed,
            "StopFailure" => Self::StopFailure,
            "SubagentStart" => Self::SubagentStart,
            "CwdChanged" => Self::CwdChanged,
            _ => return None,
        })
    }

    /// Cursor's camelCase `hook_event_name`. Disjoint from Claude's
    /// PascalCase set, so a name match alone is unambiguous.
    pub fn from_cursor(name: &str) -> Option<Self> {
        Some(match name {
            "sessionStart" => Self::SessionStart,
            "beforeSubmitPrompt" => Self::UserPrompt,
            "preToolUse" | "beforeShellExecution" | "beforeMCPExecution" | "beforeReadFile" => {
                Self::ToolUseStart
            }
            "postToolUse" => Self::ToolUseEnd,
            "afterAgentResponse" => Self::AssistantResponse,
            "postToolUseFailure" => Self::ToolUseFailed,
            "stop" => Self::AgentStop,
            _ => return None,
        })
    }
}

/// One hook event, whichever shape it arrived in.
#[derive(Clone, Debug, PartialEq)]
pub struct WebhookEvent {
    /// "claude-code", "codex", "cursor", "opencode", "pi", "seahelm-suggest", …
    pub source: String,
    pub session_id: String,
    pub event: WebhookEventType,
    pub cwd: String,
    /// Everything the payload carried that is not routing metadata. Empty
    /// where the Swift had `nil`.
    pub data: Map,
    /// The agent's own session/transcript file, when the payload names one
    /// (Claude's `transcript_path`, a generic payload's `session_path`): the
    /// resume handle for agents that resume by path.
    pub session_path: Option<String>,
    /// `seahelm_pane_id`, spliced in by the shim: a seahelmd session name or
    /// a client's pane alias. None for hooks from outside a pane.
    pub pane_id: Option<String>,
}

impl WebhookEvent {
    /// An event with no session path or pane, for building synthetic events
    /// and tests.
    pub fn new(source: &str, session_id: &str, event: WebhookEventType, cwd: &str, data: Map) -> Self {
        WebhookEvent {
            source: source.to_string(),
            session_id: session_id.to_string(),
            event,
            cwd: cwd.to_string(),
            data,
            session_path: None,
            pane_id: None,
        }
    }

    pub fn data_str(&self, key: &str) -> Option<&str> {
        self.data.get(key).and_then(Value::as_str)
    }

    /// Whether this event comes from a subagent: its `agent_id` marks a
    /// nested context, which must never speak for the pane.
    pub fn is_subagent(&self) -> bool {
        self.data.contains_key("agent_id")
    }
}

/// Why a payload was refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParseError {
    NotAnObject,
    MissingRequiredField,
    UnknownEventType(String),
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ParseError::NotAnObject => write!(f, "hook payload is not a JSON object"),
            ParseError::MissingRequiredField => write!(f, "hook payload lacks a required field"),
            ParseError::UnknownEventType(t) => write!(f, "unknown hook event type {t:?}"),
        }
    }
}

impl std::error::Error for ParseError {}

/// A hook payload as a `WebhookEvent`, or None when it is not one.
pub fn parse(payload: &Value) -> Option<WebhookEvent> {
    try_parse(payload).ok()
}

/// `parse`, saying why when it refuses.
pub fn try_parse(payload: &Value) -> Result<WebhookEvent, ParseError> {
    let json = payload.as_object().ok_or(ParseError::NotAnObject)?;
    match json.get("hook_event_name").and_then(Value::as_str) {
        Some(name) if is_cursor_hook(json, name) => parse_cursor(json, name),
        Some(name) => parse_native(json, name),
        None => parse_generic(json),
    }
}

/// `parse` on raw bytes; invalid JSON is a refusal like any other.
pub fn parse_bytes(bytes: &[u8]) -> Result<WebhookEvent, ParseError> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| ParseError::NotAnObject)?;
    try_parse(&value)
}

fn str_field<'a>(json: &'a Map, key: &str) -> Option<&'a str> {
    json.get(key).and_then(Value::as_str)
}

fn owned(json: &Map, key: &str) -> Option<String> {
    str_field(json, key).map(str::to_string)
}

fn parse_generic(json: &Map) -> Result<WebhookEvent, ParseError> {
    let (Some(source), Some(session_id), Some(raw), Some(cwd)) =
        (str_field(json, "source"), str_field(json, "session_id"), str_field(json, "event"), str_field(json, "cwd"))
    else {
        return Err(ParseError::MissingRequiredField);
    };
    let event = WebhookEventType::from_wire(raw).ok_or_else(|| ParseError::UnknownEventType(raw.into()))?;
    Ok(WebhookEvent {
        source: source.into(),
        session_id: session_id.into(),
        event,
        cwd: cwd.into(),
        data: json.get("data").and_then(Value::as_object).cloned().unwrap_or_default(),
        session_path: owned(json, "session_path"),
        pane_id: owned(json, "seahelm_pane_id"),
    })
}

fn parse_native(json: &Map, name: &str) -> Result<WebhookEvent, ParseError> {
    let (Some(session_id), Some(cwd)) = (str_field(json, "session_id"), str_field(json, "cwd")) else {
        return Err(ParseError::MissingRequiredField);
    };
    let event = WebhookEventType::from_claude_code(name).ok_or_else(|| ParseError::UnknownEventType(name.into()))?;
    // The shim declares who invoked it; guessing is only for hook configs
    // written by an older seahelm that passed no source argument.
    let source = owned(json, "seahelm_source").unwrap_or_else(|| infer_native_source(json, name).into());
    const RESERVED: [&str; 7] =
        ["hook_event_name", "session_id", "cwd", "transcript_path", "permission_mode", "seahelm_pane_id", "seahelm_source"];
    let data = json.iter().filter(|(k, _)| !RESERVED.contains(&k.as_str())).map(|(k, v)| (k.clone(), v.clone())).collect();
    Ok(WebhookEvent {
        source,
        session_id: session_id.into(),
        event,
        cwd: cwd.into(),
        data,
        // Claude Code's `transcript_path` is the session's on-disk file.
        session_path: owned(json, "transcript_path").or_else(|| owned(json, "session_path")),
        pane_id: owned(json, "seahelm_pane_id"),
    })
}

fn is_cursor_hook(json: &Map, name: &str) -> bool {
    if str_field(json, "seahelm_source") == Some("cursor") || json.contains_key("cursor_version") {
        return true;
    }
    WebhookEventType::from_cursor(name).is_some() && !json.contains_key("session_id")
}

fn parse_cursor(json: &Map, name: &str) -> Result<WebhookEvent, ParseError> {
    let event = WebhookEventType::from_cursor(name).ok_or_else(|| ParseError::UnknownEventType(name.into()))?;
    // The conversation id is also the chat directory under
    // `~/.cursor/chats/<md5(cwd)>/`, so it doubles as the title lookup key.
    let session_id = str_field(json, "conversation_id")
        .or_else(|| str_field(json, "session_id"))
        .filter(|s| !s.is_empty())
        .ok_or(ParseError::MissingRequiredField)?;
    let cwd = cursor_cwd(json).ok_or(ParseError::MissingRequiredField)?;
    const RESERVED: [&str; 7] =
        ["hook_event_name", "conversation_id", "session_id", "workspace_roots", "cwd", "seahelm_pane_id", "seahelm_source"];
    let mut data: Map =
        json.iter().filter(|(k, _)| !RESERVED.contains(&k.as_str())).map(|(k, v)| (k.clone(), v.clone())).collect();
    // Cursor counts stop-hook re-entries itself; expose that under the name
    // the rest of seahelm already understands from Claude.
    if event == WebhookEventType::AgentStop {
        if let Some(loops) = json.get("loop_count").and_then(Value::as_i64) {
            data.insert("stop_hook_active".into(), Value::Bool(loops > 0));
        }
    }
    Ok(WebhookEvent {
        source: "cursor".into(),
        session_id: session_id.into(),
        event,
        cwd,
        data,
        session_path: owned(json, "session_path"),
        pane_id: owned(json, "seahelm_pane_id"),
    })
}

fn cursor_cwd(json: &Map) -> Option<String> {
    if let Some(roots) = json.get("workspace_roots").and_then(Value::as_array) {
        // Swift read the roots as `[String]`: one non-string spoils the list.
        if roots.iter().all(Value::is_string) {
            if let Some(first) = roots.first().and_then(Value::as_str).filter(|s| !s.is_empty()) {
                return Some(first.into());
            }
        }
    }
    str_field(json, "cwd").filter(|s| !s.is_empty()).map(str::to_string)
}

/// The legacy guess for payloads with no `seahelm_source`. Key sniffing is
/// fragile and must stay conservative: `duration_ms`, `model`, `agent_id`
/// and `agent_type` were dropped from the Codex set because Claude Code
/// sends them too, which typed every Claude tool hook as Codex.
fn infer_native_source(json: &Map, name: &str) -> &'static str {
    if matches!(
        name,
        "Notification" | "WorktreeCreate" | "PostToolUseFailure" | "StopFailure" | "SubagentStart" | "SubagentStop" | "CwdChanged"
    ) {
        return "claude-code";
    }
    const CODEX_KEYS: [&str; 4] = ["turn_id", "call_id", "tool_kind", "output_preview"];
    if CODEX_KEYS.iter().any(|k| json.contains_key(*k)) {
        "codex"
    } else {
        "claude-code"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session_ref::{AgentSessionRef, Kind};
    use seahelm_core_types::AgentType;
    use serde_json::json;

    fn p(s: &str) -> Result<WebhookEvent, ParseError> {
        parse_bytes(s.as_bytes())
    }

    fn m(v: Value) -> Map {
        v.as_object().unwrap().clone()
    }

    // MARK: - Generic protocol parsing

    #[test]
    fn test_parse_generic_event() {
        let e = p(r#"{"source":"claude-code","session_id":"sess_1","event":"tool_use_start","cwd":"/tmp/project","timestamp":"2026-03-20T12:00:00Z","data":{"tool":"Bash"}}"#).unwrap();
        assert_eq!(e.source, "claude-code");
        assert_eq!(e.session_id, "sess_1");
        assert_eq!(e.event, WebhookEventType::ToolUseStart);
        assert_eq!(e.cwd, "/tmp/project");
    }

    #[test]
    fn test_parses_seahelm_pane_id() {
        let generic = r#"{"seahelm_pane_id":"seahelm-repo-main","source":"claude-code","session_id":"s","event":"worktree_create","cwd":"/p","data":{}}"#;
        assert_eq!(p(generic).unwrap().pane_id.as_deref(), Some("seahelm-repo-main"));
        let native = r#"{"seahelm_pane_id":"seahelm-repo-main","hook_event_name":"PreToolUse","session_id":"s","cwd":"/p"}"#;
        let ev = p(native).unwrap();
        assert_eq!(ev.pane_id.as_deref(), Some("seahelm-repo-main"));
        assert!(ev.data.get("seahelm_pane_id").is_none());
    }

    #[test]
    fn test_parse_generic_event_all_types() {
        for (raw, expected) in [
            ("session_start", WebhookEventType::SessionStart),
            ("tool_use_start", WebhookEventType::ToolUseStart),
            ("tool_use_end", WebhookEventType::ToolUseEnd),
            ("agent_stop", WebhookEventType::AgentStop),
            ("notification", WebhookEventType::Notification),
            ("error", WebhookEventType::Error),
            ("prompt", WebhookEventType::Prompt),
        ] {
            let e = p(&format!(r#"{{"source":"test","session_id":"s","event":"{raw}","cwd":"/tmp"}}"#)).unwrap();
            assert_eq!(e.event, expected, "Failed for {raw}");
        }
    }

    #[test]
    fn test_parse_missing_required_field_throws() {
        assert!(p(r#"{"source":"test","event":"agent_stop","cwd":"/tmp"}"#).is_err());
    }

    // MARK: - Claude Code native payload adapter

    #[test]
    fn test_parse_claude_code_pre_tool_use() {
        let e = p(r#"{"hook_event_name":"PreToolUse","session_id":"sess_abc","cwd":"/tmp/project","tool_name":"Bash","tool_input":{"command":"ls"}}"#).unwrap();
        assert_eq!(e.source, "claude-code");
        assert_eq!(e.session_id, "sess_abc");
        assert_eq!(e.event, WebhookEventType::ToolUseStart);
        assert_eq!(e.cwd, "/tmp/project");
    }

    #[test]
    fn test_parse_claude_code_stop() {
        let e = p(r#"{"hook_event_name":"Stop","session_id":"sess_abc","cwd":"/tmp/project","stop_reason":"end_turn"}"#).unwrap();
        assert_eq!(e.event, WebhookEventType::AgentStop);
    }

    #[test]
    fn test_parse_claude_code_notification() {
        let e = p(r#"{"hook_event_name":"Notification","session_id":"sess_abc","cwd":"/tmp/project","title":"Done","message":"All tests pass","level":"info"}"#).unwrap();
        assert_eq!(e.event, WebhookEventType::Notification);
        assert_eq!(e.data_str("level"), Some("info"));
        assert_eq!(e.data_str("message"), Some("All tests pass"));
    }

    #[test]
    fn test_parse_claude_code_session_start() {
        let e = p(r#"{"hook_event_name":"SessionStart","session_id":"sess_new","cwd":"/tmp/project"}"#).unwrap();
        assert_eq!(e.event, WebhookEventType::SessionStart);
        assert_eq!(e.source, "claude-code");
    }

    #[test]
    fn test_parse_claude_code_post_tool_use() {
        let e = p(r#"{"hook_event_name":"PostToolUse","session_id":"sess_abc","cwd":"/tmp/project","tool_name":"Read"}"#).unwrap();
        assert_eq!(e.event, WebhookEventType::ToolUseEnd);
    }

    #[test]
    fn test_claude_tool_hook_with_execution_metadata_is_not_codex() {
        let e = p(r#"{"hook_event_name":"PostToolUse","session_id":"sess_abc","cwd":"/tmp/project",
            "tool_name":"Bash","agent_id":"a1","agent_type":"general-purpose","duration_ms":42,
            "model":"claude-opus-5"}"#).unwrap();
        assert_eq!(e.source, "claude-code");
    }

    #[test]
    fn test_explicit_seahelm_source_wins() {
        let codex_shaped = r#"{"seahelm_source":"claude-code","hook_event_name":"PostToolUse","session_id":"s",
            "cwd":"/p","turn_id":"t1","call_id":"c1"}"#;
        assert_eq!(p(codex_shaped).unwrap().source, "claude-code");
        let claude_shaped = r#"{"seahelm_source":"codex","hook_event_name":"SubagentStop","session_id":"s","cwd":"/p"}"#;
        assert_eq!(p(claude_shaped).unwrap().source, "codex");
    }

    #[test]
    fn test_seahelm_source_is_not_leaked_into_data() {
        let e = p(r#"{"seahelm_source":"codex","hook_event_name":"PostToolUse","session_id":"s","cwd":"/p","tool_name":"Bash"}"#).unwrap();
        assert!(e.data.get("seahelm_source").is_none());
        assert_eq!(e.data_str("tool_name"), Some("Bash"));
    }

    #[test]
    fn test_hook_source_maps_to_agent_type() {
        assert_eq!(AgentType::from_hook_source("claude-code"), AgentType::ClaudeCode);
        assert_eq!(AgentType::from_hook_source("codex"), AgentType::Codex);
        assert_eq!(AgentType::from_hook_source("opencode"), AgentType::OpenCode);
        assert_eq!(AgentType::from_hook_source("pi"), AgentType::Pi);
        assert_eq!(AgentType::from_hook_source("cursor"), AgentType::Cursor);
        assert_eq!(AgentType::from_hook_source("nope"), AgentType::Unknown);
    }

    #[test]
    fn test_parse_codex_native_session_start() {
        let e = p(r#"{"hook_event_name":"SessionStart","session_id":"sess_codex","cwd":"/tmp/project","model":"gpt-5.4","turn_id":"turn_123"}"#).unwrap();
        assert_eq!(e.event, WebhookEventType::SessionStart);
        assert_eq!(e.source, "codex");
        assert_eq!(e.data_str("model"), Some("gpt-5.4"));
    }

    // MARK: - Cursor native payload adapter

    #[test]
    fn test_parse_cursor_stop_maps_loop_count_to_stop_hook_active() {
        let e1 = p(r#"{"hook_event_name":"stop","conversation_id":"conv_1","cursor_version":"1.7.2",
            "workspace_roots":["/tmp/wt"],"status":"completed","loop_count":0}"#).unwrap();
        assert_eq!(e1.source, "cursor");
        assert_eq!(e1.event, WebhookEventType::AgentStop);
        assert_eq!(e1.session_id, "conv_1");
        assert_eq!(e1.cwd, "/tmp/wt");
        assert_eq!(e1.data.get("stop_hook_active"), Some(&Value::Bool(false)));
        assert_eq!(e1.data_str("status"), Some("completed"));
        let e2 = p(r#"{"hook_event_name":"stop","conversation_id":"conv_1","cursor_version":"1.7.2",
            "workspace_roots":["/tmp/wt"],"status":"completed","loop_count":1}"#).unwrap();
        assert_eq!(e2.data.get("stop_hook_active"), Some(&Value::Bool(true)));
    }

    #[test]
    fn test_parse_cursor_after_agent_response_harvests_text() {
        let e = p(r#"{"hook_event_name":"afterAgentResponse","conversation_id":"conv_9",
            "cursor_version":"1.7.2","workspace_roots":["/tmp/wt"],
            "text":"Done.\n::seahelm-suggest:: run tests | open PR"}"#).unwrap();
        assert_eq!(e.source, "cursor");
        assert_eq!(e.event, WebhookEventType::AssistantResponse);
        assert_eq!(e.session_id, "conv_9");
        assert_eq!(e.cwd, "/tmp/wt");
        assert_eq!(e.data_str("text"), Some("Done.\n::seahelm-suggest:: run tests | open PR"));
        assert_eq!(WebhookEventType::AssistantResponse.agent_status(&Map::new()), AgentStatus::Unknown);
    }

    #[test]
    fn test_parse_cursor_before_submit_prompt() {
        let e = p(r#"{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c","cursor_version":"1.7.2",
            "workspace_roots":["/repo"],"prompt":"hello"}"#).unwrap();
        assert_eq!(e.source, "cursor");
        assert_eq!(e.event, WebhookEventType::UserPrompt);
        assert_eq!(e.cwd, "/repo");
    }

    #[test]
    fn test_parse_cursor_session_start_yields_resumable_session_ref() {
        let e = p(r#"{"seahelm_pane_id":"pane-7","seahelm_source":"cursor","hook_event_name":"sessionStart",
            "conversation_id":"15264009-b835-46b6-90fe-6ec5c818da81","workspace_roots":["/repo"]}"#).unwrap();
        assert_eq!(e.source, "cursor");
        assert_eq!(e.event, WebhookEventType::SessionStart);
        assert_eq!(e.pane_id.as_deref(), Some("pane-7"));
        let r = AgentSessionRef::from_source(&e.source, Some(&e.session_id), None).unwrap();
        assert_eq!(r.agent, "cursor");
        assert_eq!(r.kind, Kind::Id);
        assert_eq!(r.session_id, "15264009-b835-46b6-90fe-6ec5c818da81");
    }

    // MARK: - Event → AgentStatus mapping

    #[test]
    fn test_event_to_agent_status() {
        use WebhookEventType::*;
        let none = Map::new();
        assert_eq!(SessionStart.agent_status(&none), AgentStatus::Running);
        assert_eq!(ToolUseStart.agent_status(&none), AgentStatus::Running);
        assert_eq!(ToolUseEnd.agent_status(&none), AgentStatus::Running);
        assert_eq!(ToolUseFailed.agent_status(&none), AgentStatus::Running);
        assert_eq!(AgentStop.agent_status(&none), AgentStatus::Idle);
        assert_eq!(Error.agent_status(&none), AgentStatus::Error);
        assert_eq!(StopFailure.agent_status(&none), AgentStatus::Error);
        assert_eq!(Prompt.agent_status(&none), AgentStatus::Waiting);
    }

    #[test]
    fn test_notification_level_mapping() {
        let n = WebhookEventType::Notification;
        assert_eq!(n.agent_status(&m(json!({"level": "error"}))), AgentStatus::Error);
        assert_eq!(n.agent_status(&m(json!({"level": "warning"}))), AgentStatus::Waiting);
        assert_eq!(n.agent_status(&m(json!({"level": "info"}))), AgentStatus::Unknown);
        assert_eq!(n.agent_status(&Map::new()), AgentStatus::Unknown);
    }

    #[test]
    fn test_parse_claude_code_subagent_stop() {
        let e = p(r#"{"hook_event_name":"SubagentStop","session_id":"sess_abc","cwd":"/tmp/project"}"#).unwrap();
        assert_eq!(e.event, WebhookEventType::SubagentStop);
        assert_eq!(e.source, "claude-code");
    }

    // MARK: - Invalid JSON

    #[test]
    fn test_parse_invalid_json() {
        assert!(p("not json").is_err());
    }

    #[test]
    fn test_parse_unknown_event_type() {
        assert_eq!(
            p(r#"{"source":"test","session_id":"s","event":"unknown_event","cwd":"/tmp"}"#),
            Err(ParseError::UnknownEventType("unknown_event".into()))
        );
    }

    #[test]
    fn test_parse_unknown_claude_hook_type() {
        assert!(p(r#"{"hook_event_name":"UnknownHook","session_id":"s","cwd":"/tmp"}"#).is_err());
    }

    // WebhookSuggestEventTests

    #[test]
    fn test_parses_suggest_event_with_options() {
        let e = p(r#"{"source":"seahelm-suggest","session_id":"s1","event":"suggest",
            "cwd":"/repo/feat-x","data":{"options":["run tests","open PR"]}}"#).unwrap();
        assert_eq!(e.event, WebhookEventType::Suggest);
        assert_eq!(e.cwd, "/repo/feat-x");
        assert_eq!(e.data.get("options"), Some(&json!(["run tests", "open PR"])));
    }

    #[test]
    fn test_suggest_status_is_unknown() {
        assert_eq!(WebhookEventType::Suggest.agent_status(&Map::new()), AgentStatus::Unknown);
    }

    #[test]
    fn wire_names_round_trip() {
        for t in WebhookEventType::ALL {
            assert_eq!(WebhookEventType::from_wire(t.as_str()), Some(t));
        }
    }
}
