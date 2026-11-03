//! A persisted reference to an agent's own session, used to relaunch the
//! agent with its resume flag after its seahelmd session is recreated
//! (recovery, reboot, a restore into a missing session) — `AgentSessionRef.swift`.
//!
//! The reference (a session id or a session file path) is *data*, never
//! trusted shell text. Two defences: validation at the type boundary
//! rejects control characters and, for ids, anything outside a shell-inert
//! alphabet — on construction *and* on decode, so a hand-edited config
//! cannot inject through a stale ref; and every argv token is single-quoted
//! before it reaches a launch string. The table-driven argv builder mirrors
//! herdr's resume planner.

use serde::{Deserialize, Deserializer, Serialize};

/// How the agent finds the session to resume.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// An opaque session id (Claude's transcript stem, a UUID).
    Id,
    /// An absolute path to the session file. Some agents (pi, omp) resume
    /// by path more reliably than by id.
    Path,
}

/// The serde shape of a config.json `agent_sessions` value:
/// `{"agent": "claude", "kind": "id", "session_id": "…"}`. `kind` is
/// optional on decode, for configs written before it existed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct AgentSessionRef {
    /// Normalized agent name, e.g. "claude" (see [`agent_for_source`]).
    pub agent: String,
    pub kind: Kind,
    /// An id when `kind` is `Id`, an absolute path when it is `Path`. The
    /// key stays `session_id` for configs written before `kind` existed.
    pub session_id: String,
}

impl<'de> Deserialize<'de> for AgentSessionRef {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Raw {
            agent: String,
            kind: Option<Kind>,
            session_id: String,
        }
        let raw = Raw::deserialize(d)?;
        let kind = raw.kind.unwrap_or(Kind::Id);
        AgentSessionRef::new(&raw.agent, kind, &raw.session_id).ok_or_else(|| {
            serde::de::Error::custom(format!("invalid AgentSessionRef(agent={}, kind={kind:?})", raw.agent))
        })
    }
}

impl AgentSessionRef {
    /// None for anything we will not resume or cannot safely hand a shell.
    pub fn new(agent: &str, kind: Kind, session_id: &str) -> Option<Self> {
        if !is_valid(kind, session_id) || resume_argv(agent, kind, session_id).is_none() {
            return None;
        }
        Some(AgentSessionRef { agent: agent.into(), kind, session_id: session_id.into() })
    }

    /// From a hook event's `source`, preferring the session path for agents
    /// that resume by path. None for unsupported agents or when no usable
    /// reference is present.
    pub fn from_source(source: &str, session_id: Option<&str>, session_path: Option<&str>) -> Option<Self> {
        let agent = agent_for_source(source)?;
        if prefers_path(agent) {
            if let Some(r) = session_path.and_then(|p| Self::new(agent, Kind::Path, p)) {
                return Some(r);
            }
        }
        Self::new(agent, Kind::Id, session_id?)
    }

    /// The relaunch command, every token single-quoted.
    pub fn resume_command_line(&self) -> Option<String> {
        resume_argv(&self.agent, self.kind, &self.session_id).map(|argv| quote_all(&argv))
    }

    /// The fork command, every token single-quoted, `extra_args` (a yolo
    /// flag, a `--name`) appended. `prompt_file`, when given, holds the
    /// fork's first message: the shell reads (and removes) it rather than
    /// the line spelling it out, because the command is typed into the
    /// session's tty and the line discipline cuts input past 1024 bytes.
    pub fn fork_command_line(&self, extra_args: &[&str], prompt_file: Option<&str>) -> Option<String> {
        let mut argv = fork_argv(&self.agent, self.kind, &self.session_id)?;
        argv.extend(extra_args.iter().map(|a| a.to_string()));
        let mut line = quote_all(&argv);
        if let Some(file) = prompt_file {
            line += &format!(" \"$(f={}; cat \"$f\"; rm -f \"$f\")\"", single_quote(file));
        }
        Some(line)
    }

    pub fn supports_fork(&self) -> bool {
        fork_argv(&self.agent, self.kind, &self.session_id).is_some()
    }
}

/// A hook `source` → the agent name we know how to resume.
pub fn agent_for_source(source: &str) -> Option<&'static str> {
    Some(match source {
        "claude-code" | "claude" => "claude",
        "codex" => "codex",
        "copilot" => "copilot",
        "devin" => "devin",
        "droid" => "droid",
        "kimi" => "kimi",
        "mastracode" => "mastracode",
        "pi" => "pi",
        "omp" => "omp",
        "hermes" => "hermes",
        "opencode" => "opencode",
        "qodercli" => "qodercli",
        "kilo" => "kilo",
        "cursor" | "cursor-agent" => "cursor",
        _ => return None,
    })
}

/// Agents that resume more reliably from a session path than an id.
pub fn prefers_path(agent: &str) -> bool {
    agent == "pi" || agent == "omp"
}

pub fn is_valid(kind: Kind, value: &str) -> bool {
    match kind {
        Kind::Id => is_valid_session_id(value),
        Kind::Path => is_valid_session_path(value),
    }
}

/// ASCII letters, digits, `-` and `_`, at most 128: inert as shell text
/// however it is quoted.
pub fn is_valid_session_id(id: &str) -> bool {
    !id.is_empty()
        && id.chars().count() <= 128
        && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// A non-empty absolute path free of control characters. Spaces, `$` and
/// quotes are fine — the value is quoted — but control characters cannot be
/// round-tripped safely.
pub fn is_valid_session_path(path: &str) -> bool {
    !path.is_empty()
        && path.chars().count() <= 4096
        && (path.starts_with('/') || (cfg!(windows) && std::path::Path::new(path).is_absolute()))
        && !path.chars().any(char::is_control)
}

/// The relaunch argv, one row per supported (agent, kind). None when the
/// agent does not resume that way.
pub fn resume_argv(agent: &str, kind: Kind, value: &str) -> Option<Vec<String>> {
    let v = value.to_string();
    let argv: Vec<String> = match (agent, kind) {
        ("claude", Kind::Id) => vec!["claude".into(), "--resume".into(), v],
        ("codex", Kind::Id) => vec!["codex".into(), "resume".into(), v],
        ("copilot", Kind::Id) => vec!["copilot".into(), format!("--resume={v}")],
        ("devin", Kind::Id) => vec!["devin".into(), "--resume".into(), v],
        ("droid", Kind::Id) => vec!["droid".into(), "--resume".into(), v],
        ("kimi", Kind::Id) => vec!["kimi".into(), "--session".into(), v],
        ("mastracode", Kind::Id) => vec!["mastracode".into(), "--thread".into(), v],
        // pi / omp take either an id or a path.
        ("pi", _) => vec!["pi".into(), "--session".into(), v],
        ("omp", _) => vec!["omp".into(), format!("--resume={v}")],
        ("hermes", Kind::Id) => vec!["hermes".into(), "--resume".into(), v],
        ("opencode", Kind::Id) => vec!["opencode".into(), "--session".into(), v],
        ("qodercli", Kind::Id) => vec!["qodercli".into(), "--resume".into(), v],
        ("kilo", Kind::Id) => vec!["kilo".into(), "--session".into(), v],
        // Cursor Agent's CLI entrypoint is `agent`, not the IDE's `cursor`.
        ("cursor", Kind::Id) => vec!["agent".into(), "--resume".into(), v],
        _ => return None,
    };
    Some(argv)
}

/// The argv that opens a *copy* of the session under a new id, leaving the
/// original untouched. Claude finds a session by id from any directory, so
/// the fork can start in its new worktree.
pub fn fork_argv(agent: &str, kind: Kind, value: &str) -> Option<Vec<String>> {
    match (agent, kind) {
        ("claude", Kind::Id) => Some(vec!["claude".into(), "--resume".into(), value.into(), "--fork-session".into()]),
        _ => None,
    }
}

/// POSIX single quoting: `'` becomes `'\''`.
pub fn single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn quote_all(argv: &[String]) -> String {
    argv.iter().map(|a| single_quote(a)).collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    const UUID: &str = "f637907b-a9b7-429a-941c-b407fe2487ee";

    fn id(agent: &str, value: &str) -> Option<AgentSessionRef> {
        AgentSessionRef::new(agent, Kind::Id, value)
    }

    #[test]
    fn test_valid_claude_ref() {
        let r = id("claude", UUID).unwrap();
        assert_eq!(r.resume_command_line().unwrap(), format!("'claude' '--resume' '{UUID}'"));
    }

    #[test]
    fn test_from_source_mapping() {
        assert_eq!(AgentSessionRef::from_source("claude-code", Some(UUID), None).unwrap().agent, "claude");
        assert_eq!(AgentSessionRef::from_source("claude", Some(UUID), None).unwrap().agent, "claude");
        assert_eq!(AgentSessionRef::from_source("codex", Some(UUID), None).unwrap().agent, "codex");
        assert!(AgentSessionRef::from_source("bogus", Some(UUID), None).is_none());
    }

    #[test]
    fn test_codex_resume_command() {
        assert_eq!(id("codex", UUID).unwrap().resume_command_line().unwrap(), format!("'codex' 'resume' '{UUID}'"));
    }

    #[test]
    fn test_rejects_unsupported_agent() {
        assert!(id("gemini", UUID).is_none());
    }

    #[test]
    fn test_expanded_agent_argv_rows() {
        let line = |a: &str| id(a, UUID).unwrap().resume_command_line().unwrap();
        assert_eq!(line("copilot"), format!("'copilot' '--resume={UUID}'"));
        assert_eq!(line("droid"), format!("'droid' '--resume' '{UUID}'"));
        assert_eq!(line("opencode"), format!("'opencode' '--session' '{UUID}'"));
        assert_eq!(line("kimi"), format!("'kimi' '--session' '{UUID}'"));
        assert_eq!(line("cursor"), format!("'agent' '--resume' '{UUID}'"));
    }

    #[test]
    fn test_path_kind_resume() {
        let path = "/Users/dev/.pi/sessions/abc.json";
        let r = AgentSessionRef::new("pi", Kind::Path, path).unwrap();
        assert_eq!(r.kind, Kind::Path);
        assert_eq!(r.resume_command_line().unwrap(), format!("'pi' '--session' '{path}'"));
    }

    #[test]
    fn test_path_is_shell_quoted_even_with_spaces() {
        let path = "/Users/dev/My Projects/omp/session.json";
        let r = AgentSessionRef::new("omp", Kind::Path, path).unwrap();
        assert_eq!(r.resume_command_line().unwrap(), format!("'omp' '--resume={path}'"));
    }

    #[test]
    fn test_path_kind_rejects_relative_and_control_chars() {
        assert!(AgentSessionRef::new("pi", Kind::Path, "relative/path.json").is_none());
        assert!(AgentSessionRef::new("pi", Kind::Path, "/path/with\nnewline").is_none());
        assert!(AgentSessionRef::new("pi", Kind::Path, "").is_none());
    }

    #[test]
    fn test_agents_without_path_kind_reject_path() {
        assert!(AgentSessionRef::new("claude", Kind::Path, "/some/path.jsonl").is_none());
        assert!(AgentSessionRef::new("codex", Kind::Path, "/some/path").is_none());
    }

    #[test]
    fn test_source_prefers_path_for_path_agents() {
        let path = "/Users/dev/.pi/sessions/abc.json";
        let r = AgentSessionRef::from_source("pi", Some(UUID), Some(path)).unwrap();
        assert_eq!(r.kind, Kind::Path);
        assert_eq!(r.session_id, path);
        assert_eq!(AgentSessionRef::from_source("pi", Some(UUID), None).unwrap().kind, Kind::Id);
    }

    #[test]
    fn test_source_ignores_path_for_id_agents() {
        let r = AgentSessionRef::from_source("claude", Some(UUID), Some(&format!("/Users/dev/.claude/projects/x/{UUID}.jsonl")))
            .unwrap();
        assert_eq!(r.kind, Kind::Id);
        assert_eq!(r.session_id, UUID);
    }

    #[test]
    fn test_decode_backward_compat_missing_kind_defaults_to_id() {
        let r: AgentSessionRef = serde_json::from_str(&format!(r#"{{"agent":"claude","session_id":"{UUID}"}}"#)).unwrap();
        assert_eq!(r.kind, Kind::Id);
        assert_eq!(r.session_id, UUID);
    }

    #[test]
    fn test_path_ref_round_trips() {
        let r = AgentSessionRef::new("pi", Kind::Path, "/x/y.json").unwrap();
        let back: AgentSessionRef = serde_json::from_str(&serde_json::to_string(&r).unwrap()).unwrap();
        assert_eq!(r, back);
        assert_eq!(back.kind, Kind::Path);
    }

    #[test]
    fn test_ids_are_data_not_shell_text() {
        for bad in ["abc; rm -rf /", "$(whoami)", "a b", "", "id\nwith\nnewline"] {
            assert!(id("claude", bad).is_none(), "{bad:?}");
        }
    }

    #[test]
    fn test_decode_rejects_garbage() {
        assert!(serde_json::from_str::<AgentSessionRef>(r#"{"agent":"claude","session_id":"a; rm -rf /"}"#).is_err());
        assert!(serde_json::from_str::<AgentSessionRef>(&format!(r#"{{"agent":"gemini","session_id":"{UUID}"}}"#)).is_err());
    }

    #[test]
    fn test_round_trip() {
        let r = id("claude", UUID).unwrap();
        let json = serde_json::to_string(&r).unwrap();
        assert_eq!(json, format!(r#"{{"agent":"claude","kind":"id","session_id":"{UUID}"}}"#));
        assert_eq!(serde_json::from_str::<AgentSessionRef>(&json).unwrap(), r);
    }

    /// config.json's `agent_sessions` is a map of pane → ref.
    #[test]
    fn test_config_round_trip_carries_agent_sessions() {
        let mut sessions = BTreeMap::new();
        sessions.insert("seahelm-repo-main".to_string(), id("claude", UUID).unwrap());
        let json = serde_json::to_string(&sessions).unwrap();
        let back: BTreeMap<String, AgentSessionRef> = serde_json::from_str(&json).unwrap();
        assert_eq!(back["seahelm-repo-main"].session_id, UUID);
    }

    #[test]
    fn test_config_backward_compat_missing_key() {
        #[derive(Deserialize)]
        struct Config {
            #[serde(default)]
            agent_sessions: BTreeMap<String, AgentSessionRef>,
        }
        let c: Config = serde_json::from_str(r#"{"workspace_paths":[]}"#).unwrap();
        assert!(c.agent_sessions.is_empty());
    }

    #[test]
    fn test_claude_fork_command_quotes_every_token() {
        let r = id("claude", UUID).unwrap();
        assert!(r.supports_fork());
        assert_eq!(r.fork_command_line(&[], None).unwrap(), format!("'claude' '--resume' '{UUID}' '--fork-session'"));
        assert_eq!(
            r.fork_command_line(&["--dangerously-skip-permissions"], None).unwrap(),
            format!("'claude' '--resume' '{UUID}' '--fork-session' '--dangerously-skip-permissions'")
        );
    }

    /// The prompt is read from a file, not spelled out: the line is typed
    /// into a tty that cuts input past 1024 bytes.
    #[cfg(unix)]
    #[test]
    fn test_fork_prompt_is_read_from_its_file_as_one_argument() {
        let r = id("claude", UUID).unwrap();
        let dir = tempfile::tempdir().unwrap();
        let prompt = "carry on, it's `here` $HOME. ".repeat(60);
        let file = dir.path().join("prompt.txt");
        std::fs::write(&file, &prompt).unwrap();
        let file = file.to_str().unwrap();
        let line = r.fork_command_line(&[], Some(file)).unwrap();
        assert!(line.len() < 150 + file.len());

        // Swap the agent for printf to see the argv the shell hands it.
        let probe = line.replace(&format!("'claude' '--resume' '{UUID}' '--fork-session'"), "printf '%s\\n'");
        let out = std::process::Command::new("/bin/sh").arg("-c").arg(&probe).output().unwrap();
        assert_eq!(String::from_utf8(out.stdout).unwrap(), prompt + "\n");
        assert!(!std::path::Path::new(file).exists());
    }

    #[test]
    fn test_agents_without_fork_return_nil() {
        let codex = id("codex", "abc-123").unwrap();
        assert!(!codex.supports_fork());
        assert!(codex.fork_command_line(&[], None).is_none());
    }
}
