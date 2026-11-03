//! The vocabulary every part of seahelm-core speaks: what state a pane is in,
//! what kind of agent runs in it, and the one event language the hook, scan
//! and program-status paths all translate into (`NormalizedEvent`).
//!
//! Ported from the Swift app (`Sources/Core/AgentStatus.swift`,
//! `AgentType.swift`, `ActivityEvent.swift`, `PaneInfo.swift`,
//! `Sources/Status/NormalizedEvent.swift`). Wire names are the Swift raw
//! values, so JSON from the core reads the same as JSON from the app.

use serde::{Deserialize, Serialize};

/// Seconds since the Unix epoch. The Swift app's `Date`, as the wire carries it.
pub type Timestamp = f64;

pub fn now() -> Timestamp {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum AgentStatus {
    Running,
    Idle,
    Waiting,
    Error,
    Exited,
    #[default]
    Unknown,
}

impl AgentStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentStatus::Running => "Running",
            AgentStatus::Idle => "Idle",
            AgentStatus::Waiting => "Waiting",
            AgentStatus::Error => "Error",
            AgentStatus::Exited => "Exited",
            AgentStatus::Unknown => "Unknown",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "Running" => AgentStatus::Running,
            "Idle" => AgentStatus::Idle,
            "Waiting" => AgentStatus::Waiting,
            "Error" => AgentStatus::Error,
            "Exited" => AgentStatus::Exited,
            "Unknown" => AgentStatus::Unknown,
            _ => return None,
        })
    }

    /// Rollup priority: `waiting` (blocked on the user) ranks highest, as it
    /// most needs attention.
    pub fn priority(self) -> u8 {
        match self {
            AgentStatus::Waiting => 6,
            AgentStatus::Error => 5,
            AgentStatus::Exited => 4,
            AgentStatus::Running => 3,
            AgentStatus::Idle => 2,
            AgentStatus::Unknown => 1,
        }
    }

    pub fn is_urgent(self) -> bool {
        matches!(self, AgentStatus::Error | AgentStatus::Waiting)
    }

    pub fn is_active(self) -> bool {
        matches!(self, AgentStatus::Running | AgentStatus::Waiting)
    }

    pub fn highest_priority(statuses: impl IntoIterator<Item = AgentStatus>) -> AgentStatus {
        statuses.into_iter().max_by_key(|s| s.priority()).unwrap_or(AgentStatus::Unknown)
    }

    /// The text glyph notifications and chat use (not the dashboard dot).
    pub fn icon(self) -> &'static str {
        match self {
            AgentStatus::Running => "●",
            AgentStatus::Idle => "○",
            AgentStatus::Waiting => "◐",
            AgentStatus::Error => "✕",
            AgentStatus::Exited => "◻",
            AgentStatus::Unknown => "?",
        }
    }
}

/// What runs in a pane. Wire names are the Swift case names (`claudeCode`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentType {
    ClaudeCode,
    Codex,
    OpenCode,
    Gemini,
    Cline,
    Goose,
    Amp,
    Aider,
    Cursor,
    Kiro,
    Pi,
    Brew,
    Btop,
    Top,
    Htop,
    Docker,
    Npm,
    Yarn,
    Make,
    Cargo,
    Go,
    Python,
    Pip,
    ShellCommand,
    #[default]
    Unknown,
}

impl AgentType {
    pub fn display_name(self) -> &'static str {
        use AgentType::*;
        match self {
            ClaudeCode => "Claude Code",
            Codex => "Codex",
            OpenCode => "OpenCode",
            Gemini => "Gemini",
            Cline => "Cline",
            Goose => "Goose",
            Amp => "Amp",
            Aider => "Aider",
            Cursor => "Cursor",
            Kiro => "Kiro",
            Pi => "Pi",
            Brew => "Homebrew",
            Btop => "btop",
            Top => "top",
            Htop => "htop",
            Docker => "Docker",
            Npm => "npm",
            Yarn => "Yarn",
            Make => "Make",
            Cargo => "Cargo",
            Go => "Go",
            Python => "Python",
            Pip => "pip",
            ShellCommand => "Shell",
            Unknown => "Unknown",
        }
    }

    /// The manifest that holds this agent's detection rules; anything else
    /// uses the generic "agent" manifest.
    pub fn manifest_id(self) -> &'static str {
        use AgentType::*;
        match self {
            ClaudeCode => "claude",
            Codex => "codex",
            OpenCode => "opencode",
            Gemini => "gemini",
            Cline => "cline",
            Goose => "goose",
            Amp => "amp",
            Aider => "aider",
            Cursor => "cursor",
            Kiro => "kiro",
            Pi => "pi",
            _ => "agent",
        }
    }

    pub fn from_manifest_id(id: &str) -> AgentType {
        use AgentType::*;
        match id {
            "claude" => ClaudeCode,
            "codex" => Codex,
            "opencode" => OpenCode,
            "gemini" => Gemini,
            "cline" => Cline,
            "goose" => Goose,
            "amp" => Amp,
            "aider" => Aider,
            "cursor" => Cursor,
            "kiro" => Kiro,
            "pi" => Pi,
            _ => Unknown,
        }
    }

    /// The agent a hook event's `source` names: manifest ids, except Claude,
    /// which calls itself "claude-code".
    pub fn from_hook_source(source: &str) -> AgentType {
        if source == "claude-code" {
            AgentType::ClaudeCode
        } else {
            AgentType::from_manifest_id(source)
        }
    }

    pub fn is_ai_agent(self) -> bool {
        use AgentType::*;
        matches!(self, ClaudeCode | Codex | OpenCode | Gemini | Cline | Goose | Amp | Aider | Cursor | Kiro | Pi)
    }

    pub fn is_shell_task(self) -> bool {
        !self.is_ai_agent() && self != AgentType::Unknown
    }

    /// An AI agent named in lowercased screen text, most specific first.
    pub fn detect_from_lowercased(content: &str) -> AgentType {
        use AgentType::*;
        const PATTERNS: &[(&str, AgentType)] = &[
            ("opencode", OpenCode),
            ("claude", ClaudeCode),
            ("codex", Codex),
            ("gemini", Gemini),
            ("cline", Cline),
            ("goose", Goose),
            ("aider", Aider),
            ("cursor", Cursor),
            ("kiro", Kiro),
            ("amp ", Amp),
        ];
        PATTERNS.iter().find(|(p, _)| content.contains(p)).map(|(_, t)| *t).unwrap_or(Unknown)
    }

    /// A shell task from a command line: leading `KEY=value` skipped, a path
    /// reduced to its basename; any other first word is a plain shell command.
    pub fn detect_from_command(command: &str) -> AgentType {
        use AgentType::*;
        for token in command.split(' ').filter(|t| !t.is_empty()).take(11) {
            if token.contains('=') && !token.starts_with('=') {
                continue;
            }
            let name = token.rsplit('/').next().unwrap_or(token).to_lowercase();
            return match name.as_str() {
                "brew" => Brew,
                "btop" => Btop,
                "top" => Top,
                "htop" => Htop,
                "docker" => Docker,
                "npm" | "npx" => Npm,
                "yarn" => Yarn,
                "make" => Make,
                "cargo" => Cargo,
                "go" => Go,
                "python" | "python3" => Python,
                "pip" | "pip3" => Pip,
                _ => ShellCommand,
            };
        }
        Unknown
    }
}

/// Which signal decides a pane's state (an agent manifest's `authority`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Authority {
    /// The screen decides, except: a hook `running` beats a screen `idle`,
    /// and a fresh hook `idle` beats a screen `running`.
    #[default]
    SessionOnly,
    /// The hooks decide.
    FullLifecycle,
    /// The screen decides.
    ScreenOnly,
}

impl Authority {
    pub fn parse(s: &str) -> Authority {
        match s {
            "full_lifecycle" => Authority::FullLifecycle,
            "screen_only" => Authority::ScreenOnly,
            _ => Authority::SessionOnly,
        }
    }
}

/// One tool call, for the activity log.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ActivityEvent {
    pub tool: String,
    pub detail: String,
    pub is_error: bool,
    pub timestamp: Timestamp,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskItemStatus {
    Pending,
    InProgress,
    Completed,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskItem {
    pub id: String,
    pub subject: String,
    pub status: TaskItemStatus,
}

/// How a question is answered in Claude's AskUserQuestion dialog.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionFlags {
    pub multi_select: bool,
    /// Answering this question lands on the review page instead of submitting.
    pub review_after: bool,
    /// Multi-select rows toggled on so far (0-based).
    pub checked: Vec<usize>,
    /// Row the dialog's cursor was last moved to (0-based).
    pub cursor: usize,
    /// The AskUserQuestion call (`tool_use_id`) its questions share.
    pub ask_id: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionSpec {
    pub prompt: String,
    pub options: Vec<String>,
    pub flags: QuestionFlags,
}

/// OSC 7501 state of a pane's live root record.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProgramState {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
}

impl ProgramState {
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "idle" => ProgramState::Idle,
            "working" => ProgramState::Working,
            "done" => ProgramState::Done,
            "blocked" => ProgramState::Blocked,
            "error" => ProgramState::Error,
            _ => return None,
        })
    }
}

/// A pane's live OSC 7501 root record, as `seahelmd snapshot` reports it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProgramStatus {
    pub state: ProgramState,
    /// `permission` / `question` / `auth`, for `blocked`.
    pub kind: Option<String>,
    pub progress: Option<u8>,
    pub app: String,
    pub title: String,
    pub msg: String,
}

impl ProgramStatus {
    /// In seahelm's vocabulary. `done` is at rest like `idle`.
    pub fn agent_status(&self) -> AgentStatus {
        match self.state {
            ProgramState::Working => AgentStatus::Running,
            ProgramState::Blocked => AgentStatus::Waiting,
            ProgramState::Idle | ProgramState::Done => AgentStatus::Idle,
            ProgramState::Error => AgentStatus::Error,
        }
    }

    /// The line to show beside the status.
    pub fn message(&self) -> String {
        if !self.msg.is_empty() {
            return self.msg.clone();
        }
        if self.state == ProgramState::Blocked {
            match self.kind.as_deref() {
                Some("permission") => return "Needs permission".into(),
                Some("question") => return "Needs an answer".into(),
                Some("auth") => return "Needs a login".into(),
                _ => {}
            }
        }
        String::new()
    }
}

/// Where a normalized event came from.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "type", content = "name")]
pub enum EventSource {
    Scan,
    /// The hook's raw source, e.g. "claude-code", "codex".
    Hook(String),
    Osc7501,
}

/// The one input language. Hook-native kinds carry no status: the registry
/// derives the hook status from them. `ScreenObserved` carries what the scan
/// saw.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind")]
pub enum EventKind {
    /// session_start / worktree_create / subagent_start.
    SessionStarted { label: String },
    UserPrompt { text: String },
    /// tool_use_start / end / failed.
    ToolUse { activity: ActivityEvent },
    /// The agent is waiting for input.
    AwaitingInput { text: String },
    /// agent_stop (success) / stop_failure (not).
    AgentStopped { success: bool },
    Notification { level: String, text: String },
    TaskUpdate { tasks: Vec<TaskItem> },
    /// Agent-authored candidate next orders.
    Suggest { options: Vec<String> },
    /// AskUserQuestion: blocked on a choice; further questions of the same
    /// call ride along in `followups` (prompts pre-tagged "(i/N)").
    Question { prompt: String, options: Vec<String>, followups: Vec<QuestionSpec>, flags: QuestionFlags },
    ScreenObserved {
        status: AgentStatus,
        message: String,
        activity: Vec<ActivityEvent>,
        command_line: Option<String>,
        agent_type: AgentType,
        round_duration: f64,
        tasks: Vec<TaskItem>,
        background_busy: bool,
    },
    /// The pane's live OSC 7501 root record changed; None: nothing live.
    ProgramStatus { record: Option<ProgramStatus> },
}

/// One event about one pane. `pane` is the core's pane key: the seahelmd
/// session name.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct NormalizedEvent {
    pub pane: String,
    pub source: EventSource,
    pub kind: EventKind,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn statuses_rank_waiting_first() {
        use AgentStatus::*;
        assert_eq!(AgentStatus::highest_priority([Idle, Running, Waiting, Error]), Waiting);
        assert_eq!(AgentStatus::highest_priority([]), Unknown);
        assert!(Error.is_urgent() && !Running.is_urgent());
    }

    #[test]
    fn wire_names_are_the_swift_raw_values() {
        assert_eq!(serde_json_like(&AgentStatus::Waiting), "\"Waiting\"");
        assert_eq!(serde_json_like(&AgentType::ClaudeCode), "\"claudeCode\"");
        assert_eq!(serde_json_like(&AgentType::OpenCode), "\"openCode\"");
    }

    fn serde_json_like<T: Serialize>(v: &T) -> String {
        serde_json::to_string(v).unwrap()
    }

    #[test]
    fn commands_name_shell_tasks() {
        assert_eq!(AgentType::detect_from_command("FOO=1 /usr/local/bin/brew install x"), AgentType::Brew);
        assert_eq!(AgentType::detect_from_command("vim x"), AgentType::ShellCommand);
        assert_eq!(AgentType::detect_from_command(""), AgentType::Unknown);
        assert_eq!(AgentType::from_hook_source("claude-code"), AgentType::ClaudeCode);
        assert_eq!(AgentType::from_hook_source("opencode"), AgentType::OpenCode);
    }

    #[test]
    fn program_status_reads_as_agent_status() {
        let p = ProgramStatus {
            state: ProgramState::Blocked,
            kind: Some("permission".into()),
            progress: None,
            app: "claude-code".into(),
            title: String::new(),
            msg: String::new(),
        };
        assert_eq!(p.agent_status(), AgentStatus::Waiting);
        assert_eq!(p.message(), "Needs permission");
    }
}
