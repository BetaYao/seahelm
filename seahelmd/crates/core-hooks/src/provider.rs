//! Per-session hook state and where each pane's agent is
//! (`WebhookStatusProvider.swift`), without its queue or callbacks: one call
//! per event, and everything it would have called back with is returned in
//! an [`Output`].
//!
//! It keeps three things the registry does not:
//!
//! - **Sessions** by agent session id, filed under the worktree the hook
//!   `cwd` matches (the *longest* known prefix: Claude's own worktrees live
//!   inside the worktree they were made from). Their statuses roll up per
//!   worktree, and they carry the last message, prompt and task list.
//! - **Location** per pane: the cwd, unless the agent's tool calls say it is
//!   working elsewhere ([`crate::location`]); and the worktrees each pane's
//!   agent created, so a move into one reads as `created_by_agent`.
//! - **Discovery**: a location that names a worktree nobody tracks yet is
//!   reported as `new_worktree`, at most once per path per 15 s, since the
//!   check runs on every event.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use seahelm_core_types::{AgentStatus, TaskItem, TaskItemStatus, Timestamp};
use serde_json::Value;

use crate::event::{WebhookEvent, WebhookEventType as T};
use crate::location::{self, Signal};
use crate::session_ref::AgentSessionRef;
use crate::{activity, paths, prompt, titles, Map};

/// How long one path's discovery request stands before it may be repeated.
const DISCOVERY_REQUEST_INTERVAL: f64 = 15.0;

/// Sessions with no event for this long are pruned on the next worktree update.
const SESSION_TTL: f64 = 3600.0;

/// What one event changed.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Output {
    /// The rollup of each worktree the event was filed under, after it. The
    /// Swift fired `onStatusChanged` for every filed event, so this repeats
    /// rather than reporting edges only.
    pub worktree_status: Vec<(String, AgentStatus)>,
    /// A worktree the agent is in that nobody tracks yet (canonical path),
    /// and the pane whose event said so: ask discovery to pick it up.
    pub new_worktree: Option<(String, Option<String>)>,
    /// Where the event's pane's agent is now, on every event that names a
    /// pane and is not a subagent's. Not edge-cached: an owner that could
    /// not act on it yet gets it again on the next event.
    pub pane_location: Option<PaneLocation>,
    /// A resume reference for the session, for a filed, non-subagent event
    /// from an agent we can resume.
    pub session_ref: Option<ResolvedSessionRef>,
    /// The person's prompt, when the event was one (machine-injected turns
    /// and paste wrappers removed).
    pub user_prompt: Option<String>,
    /// The filed worktree's current task list (that of its most recent session).
    pub tasks: Option<Vec<TaskItem>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PaneLocation {
    pub pane: String,
    /// The known worktree the location falls in, or None when it matches none.
    pub worktree: Option<String>,
    /// The location as the agent spelled it: the hook cwd, or where its
    /// latest placed tool call went.
    pub location: String,
    /// Whether `worktree` is one this pane's agent created itself.
    pub created_by_agent: bool,
}

/// A resume reference and where it belongs. `pane` is None for hooks that
/// predate the pane-id splice; the owner then routes by `worktree`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolvedSessionRef {
    pub worktree: String,
    pub pane: Option<String>,
    pub session_ref: AgentSessionRef,
}

#[derive(Clone, Debug)]
struct SessionState {
    worktree: String,
    status: AgentStatus,
    last_event: Timestamp,
    /// Tie-break for events sharing a timestamp: later wins.
    seq: u64,
    last_message: Option<String>,
    last_user_prompt: Option<String>,
    tasks: Vec<TaskItem>,
    next_task_id: u64,
}

type PromptLookup = Box<dyn FnMut(&str) -> Option<String> + Send>;

pub struct Provider {
    sessions: HashMap<String, SessionState>,
    known_worktrees: Vec<String>,
    discovery_requested_at: HashMap<String, Timestamp>,
    /// Per pane, where its agent's latest placed tool call went. Cleared by
    /// a shell command that runs in the cwd; left alone by events that name
    /// no place (Stop, prompts, reads) — those still carry the project cwd,
    /// and reading them as a move back would flip the location every turn.
    last_tool_target: HashMap<String, String>,
    /// Per pane, the worktrees its agent created, as the tool call spelled them.
    created_worktrees: HashMap<String, HashSet<String>>,
    home: String,
    resolve_symlinks: bool,
    codex_prompt_lookup: Option<PromptLookup>,
    seq: u64,
}

impl Default for Provider {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for Provider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Provider")
            .field("sessions", &self.sessions.len())
            .field("known_worktrees", &self.known_worktrees)
            .finish_non_exhaustive()
    }
}

impl Provider {
    /// A provider for the current user: `~` and the Codex prompt fallback
    /// (`~/.codex/sessions`) resolve against `HOME`.
    pub fn new() -> Self {
        Self::with_home(crate::home_dir())
    }

    /// A provider whose `~` and Codex sessions live under `home`.
    pub fn with_home(home: PathBuf) -> Self {
        let lookup_home = home.clone();
        Provider {
            sessions: HashMap::new(),
            known_worktrees: Vec::new(),
            discovery_requested_at: HashMap::new(),
            last_tool_target: HashMap::new(),
            created_worktrees: HashMap::new(),
            home: home.to_string_lossy().into_owned(),
            resolve_symlinks: true,
            codex_prompt_lookup: Some(Box::new(move |id| titles::codex_prompt(&lookup_home, id))),
            seq: 0,
        }
    }

    /// Codex's UserPromptSubmit carries no text; the Swift read it back out
    /// of Codex's own session log. Replace (or with None, disable) that.
    pub fn set_codex_prompt_lookup(&mut self, lookup: Option<PromptLookup>) {
        self.codex_prompt_lookup = lookup;
    }

    /// Paths are compared after resolving symlinks as far as they exist
    /// (`/var` vs `/private/var`, a symlinked workspace), as the Swift did.
    /// Off: compare lexically only, touching no disk.
    pub fn set_resolve_symlinks(&mut self, on: bool) {
        self.resolve_symlinks = on;
    }

    /// The worktrees events are filed under. Sessions of worktrees no longer
    /// listed are dropped, and so are sessions silent for an hour.
    pub fn set_worktrees(&mut self, paths: &[String], now: Timestamp) {
        self.known_worktrees = paths.iter().map(|p| self.canonicalize(p)).collect();
        let known = &self.known_worktrees;
        self.sessions.retain(|_, s| known.contains(&s.worktree) && s.last_event > now - SESSION_TTL);
    }

    /// The known worktree `path` (already canonical) belongs to: itself, or
    /// the longest known worktree it sits inside.
    pub fn match_worktree(&self, path: &str) -> Option<String> {
        if self.known_worktrees.iter().any(|w| w == path) {
            return Some(path.to_string());
        }
        self.known_worktrees
            .iter()
            .filter(|w| is_inside(path, w))
            .max_by_key(|w| w.len())
            .cloned()
    }

    /// `path` as the provider compares it: standardized, symlinks resolved
    /// as far as it exists (unless turned off), no trailing separator.
    pub fn canonicalize(&self, path: &str) -> String {
        let mut s = paths::standardize(path);
        if self.resolve_symlinks {
            s = paths::resolve_existing(&s);
        }
        while s.len() > 1 && (s.ends_with('/') || (cfg!(windows) && s.ends_with('\\') && !s.ends_with(":\\"))) {
            s.pop();
        }
        s
    }

    /// One hook event. `is_worktree_root` says whether a path is the root of
    /// a git worktree (`<path>/.git` exists); it is only asked about a
    /// location inside a known worktree that is not that worktree, and a
    /// probe that times out must answer false — on a wedged volume "yes"
    /// would make every subdirectory look like a new worktree.
    pub fn handle(&mut self, ev: &WebhookEvent, now: Timestamp, is_worktree_root: &mut dyn FnMut(&str) -> bool) -> Output {
        let mut out = Output::default();
        let canon_cwd = self.canonicalize(&ev.cwd);
        let subagent = ev.is_subagent();

        // Where the agent is working: its cwd, unless its tool calls say
        // otherwise. A subagent's events must not speak for the pane.
        let mut location = ev.cwd.clone();
        let pane = ev.pane_id.as_ref().filter(|_| !subagent);
        if let Some(pane) = pane {
            match location::signal(ev.event, &ev.data, &ev.cwd, &self.home) {
                Some(Signal::Directory(dir)) => {
                    self.last_tool_target.insert(pane.clone(), dir);
                }
                Some(Signal::Cwd) => {
                    self.last_tool_target.remove(pane);
                }
                None => {}
            }
            if let Some(created) = location::created_worktree(ev.event, &ev.data, &ev.cwd, &self.home) {
                self.created_worktrees.entry(pane.clone()).or_default().insert(created);
            }
            if let Some(target) = self.last_tool_target.get(pane) {
                location = target.clone();
            }
        }
        let canon_location = self.canonicalize(&location);

        // A worktree nobody tracks yet: the location matches nothing, or it
        // sits *inside* a known worktree while being a worktree root itself —
        // exactly where Claude's EnterWorktree puts one.
        let pre = self.match_worktree(&canon_location);
        let untracked = match &pre {
            None => true,
            Some(w) => *w != canon_location && is_worktree_root(&canon_location),
        };
        if untracked && self.request_discovery(&canon_location, now) {
            out.new_worktree = Some((canon_location.clone(), ev.pane_id.clone()));
        }

        if let Some(pane) = pane {
            let worktree = self.match_worktree(&canon_location);
            let created_by_agent = worktree.as_ref().is_some_and(|w| {
                self.created_worktrees.get(pane).is_some_and(|set| set.iter().any(|c| self.canonicalize(c) == *w))
            });
            out.pane_location = Some(PaneLocation { pane: pane.clone(), worktree, location, created_by_agent });
        }

        // Status stays filed by the hook cwd: the rollup belongs to the
        // pane's worktree, not to the one a single command visited.
        let Some(worktree) = self.match_worktree(&canon_cwd) else { return out };

        let status = ev.event.agent_status(&ev.data);
        let message = extract_message(ev);
        let user_prompt = extract_user_prompt(ev).or_else(|| self.fallback_user_prompt(ev));
        self.seq += 1;
        let seq = self.seq;
        let session = self.sessions.entry(ev.session_id.clone()).or_insert_with(|| SessionState {
            worktree: worktree.clone(),
            status,
            last_event: now,
            seq,
            last_message: None,
            last_user_prompt: None,
            tasks: Vec::new(),
            next_task_id: 1,
        });
        session.status = status;
        session.last_event = now;
        session.seq = seq;
        if message.is_some() {
            session.last_message = message;
        }
        if user_prompt.is_some() {
            session.last_user_prompt = user_prompt.clone();
        }
        apply_task_event(ev, session);

        // Persist a resume ref for agents we can resume — never from a
        // subagent, whose nested context would revive the wrong session.
        if !subagent {
            if let Some(session_ref) =
                AgentSessionRef::from_source(&ev.source, Some(&ev.session_id), ev.session_path.as_deref())
            {
                out.session_ref = Some(ResolvedSessionRef { worktree: worktree.clone(), pane: ev.pane_id.clone(), session_ref });
            }
        }

        out.worktree_status.push((worktree.clone(), self.status(&worktree)));
        out.user_prompt = user_prompt;
        out.tasks = Some(self.tasks(&worktree));
        out
    }

    /// The worktree's rollup: the highest-priority status of its sessions.
    pub fn status(&self, worktree: &str) -> AgentStatus {
        let canon = self.canonicalize(worktree);
        AgentStatus::highest_priority(self.sessions.values().filter(|s| s.worktree == canon).map(|s| s.status))
    }

    pub fn last_message(&self, worktree: &str) -> Option<String> {
        self.latest(worktree).and_then(|s| s.last_message.clone())
    }

    pub fn last_user_prompt(&self, worktree: &str) -> Option<String> {
        self.latest(worktree).and_then(|s| s.last_user_prompt.clone())
    }

    /// The task list of the worktree's most recent session.
    pub fn tasks(&self, worktree: &str) -> Vec<TaskItem> {
        if self.sessions.is_empty() {
            return Vec::new();
        }
        self.latest(worktree).map(|s| s.tasks.clone()).unwrap_or_default()
    }

    fn latest(&self, worktree: &str) -> Option<&SessionState> {
        let canon = self.canonicalize(worktree);
        self.sessions
            .values()
            .filter(|s| s.worktree == canon)
            .max_by(|a, b| a.last_event.total_cmp(&b.last_event).then(a.seq.cmp(&b.seq)))
    }

    fn fallback_user_prompt(&mut self, ev: &WebhookEvent) -> Option<String> {
        if ev.source != "codex" || ev.event != T::UserPrompt {
            return None;
        }
        self.codex_prompt_lookup.as_mut().and_then(|lookup| lookup(&ev.session_id))
    }

    /// Whether to ask for discovery of `path` now; records the request.
    fn request_discovery(&mut self, path: &str, now: Timestamp) -> bool {
        if self.discovery_requested_at.get(path).is_some_and(|last| now - last < DISCOVERY_REQUEST_INTERVAL) {
            return false;
        }
        self.discovery_requested_at.retain(|_, at| now - *at < DISCOVERY_REQUEST_INTERVAL);
        self.discovery_requested_at.insert(path.to_string(), now);
        true
    }
}

/// The filesystem probe the Swift used: `<path>/.git` exists (a file in a
/// linked worktree, a directory in the main one). No timeout of its own;
/// a caller on a volume that can hang should run it under one.
pub fn probe_worktree_root(path: &str) -> bool {
    std::path::Path::new(path).join(".git").exists()
}

fn is_inside(path: &str, dir: &str) -> bool {
    let Some(rest) = path.strip_prefix(dir) else { return false };
    rest.starts_with('/') || (cfg!(windows) && rest.starts_with('\\'))
}

/// The user's prompt in a `user_prompt` event: the first non-empty field
/// of `prompt`, `input`, `text`, `message`, as a human should see it.
fn extract_user_prompt(ev: &WebhookEvent) -> Option<String> {
    if ev.event != T::UserPrompt {
        return None;
    }
    let raw = ["prompt", "input", "text", "message"].iter().find_map(|k| ev.data_str(k).filter(|s| !s.is_empty()))?;
    prompt::human_text(raw)
}

fn tool_summary(data: &Map, is_error: bool) -> Option<String> {
    let tool = data.get("tool_name")?.as_str()?;
    let empty = Map::new();
    let input = data.get("tool_input").and_then(Value::as_object).unwrap_or(&empty);
    Some(activity::summary(tool, input, is_error))
}

/// The human-readable line an event leaves on its session.
fn extract_message(ev: &WebhookEvent) -> Option<String> {
    let text = |k: &str| ev.data_str(k).map(str::to_string);
    match ev.event {
        T::ToolUseStart | T::ToolUseEnd => tool_summary(&ev.data, false),
        T::AgentStop => {
            let reason = ev.data_str("stop_reason").map(|r| r.trim().to_lowercase());
            Some(
                match reason.as_deref() {
                    None | Some("" | "done" | "completed" | "complete" | "success" | "succeeded") => "Task completed",
                    Some("cancelled" | "canceled") => "Task cancelled",
                    _ => "Stopped",
                }
                .into(),
            )
        }
        T::Error => Some(text("message").unwrap_or_else(|| "Error occurred".into())),
        T::Prompt => Some(text("message").unwrap_or_else(|| "Waiting for input".into())),
        T::Notification => text("message").or_else(|| text("title")),
        T::SessionStart => Some("Session started".into()),
        T::WorktreeCreate => Some("Creating worktree".into()),
        T::UserPrompt => Some("Processing prompt".into()),
        T::ToolUseFailed => Some(tool_summary(&ev.data, true).unwrap_or_else(|| "Tool failed".into())),
        T::StopFailure => Some(text("error").unwrap_or_else(|| "API error".into())),
        T::SubagentStart => Some("Subagent started".into()),
        T::SubagentStop | T::CwdChanged | T::Suggest | T::AssistantResponse => None,
    }
}

/// TaskCreate / TaskUpdate (from PostToolUse) edit the session's task list;
/// a Stop clears it.
fn apply_task_event(ev: &WebhookEvent, session: &mut SessionState) {
    if ev.event == T::AgentStop {
        session.tasks.clear();
        session.next_task_id = 1;
        return;
    }
    if ev.event != T::ToolUseEnd {
        return;
    }
    let (Some(tool), Some(input)) = (ev.data_str("tool_name"), ev.data.get("tool_input").and_then(Value::as_object)) else {
        return;
    };
    let field = |k: &str| input.get(k).and_then(Value::as_str);
    match tool {
        "TaskCreate" => {
            let Some(subject) = field("subject") else { return };
            session.tasks.push(TaskItem {
                id: session.next_task_id.to_string(),
                subject: subject.into(),
                status: TaskItemStatus::Pending,
            });
            session.next_task_id += 1;
        }
        "TaskUpdate" => {
            let (Some(id), Some(status)) = (field("taskId"), field("status").and_then(task_status)) else { return };
            if let Some(task) = session.tasks.iter_mut().find(|t| t.id == id) {
                task.status = status;
            }
        }
        _ => {}
    }
}

fn task_status(s: &str) -> Option<TaskItemStatus> {
    Some(match s {
        "pending" => TaskItemStatus::Pending,
        "in_progress" => TaskItemStatus::InProgress,
        "completed" => TaskItemStatus::Completed,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::cell::RefCell;
    use std::rc::Rc;

    const UUID: &str = "f637907b-a9b7-429a-941c-b407fe2487ee";

    fn no_probe() -> impl FnMut(&str) -> bool {
        |_| false
    }

    fn make_provider() -> Provider {
        let mut p = Provider::with_home("/home/me".into());
        p.set_codex_prompt_lookup(None);
        // These paths are made up; compare them as text on every platform.
        p.set_resolve_symlinks(false);
        p.set_worktrees(&["/projects/repo/main".into(), "/projects/repo/feature".into()], 0.0);
        p
    }

    fn make_event(session: &str, event: T, cwd: &str, data: Value) -> WebhookEvent {
        WebhookEvent::new("claude-code", session, event, cwd, data.as_object().cloned().unwrap_or_default())
    }

    fn handle(p: &mut Provider, ev: WebhookEvent) -> Output {
        p.handle(&ev, 1.0, &mut no_probe())
    }

    const MAIN: &str = "/projects/repo/main";
    const FEATURE: &str = "/projects/repo/feature";

    // MARK: - Basic event handling

    #[test]
    fn test_no_events_returns_unknown() {
        assert_eq!(make_provider().status(MAIN), AgentStatus::Unknown);
    }

    #[test]
    fn test_session_start_sets_running() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::SessionStart, MAIN, json!({})));
        assert_eq!(p.status(MAIN), AgentStatus::Running);
    }

    #[test]
    fn test_agent_stop_sets_idle() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::SessionStart, MAIN, json!({})));
        handle(&mut p, make_event("s1", T::AgentStop, MAIN, json!({})));
        assert_eq!(p.status(MAIN), AgentStatus::Idle);
    }

    #[test]
    fn test_tool_use_keeps_running() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::SessionStart, MAIN, json!({})));
        handle(&mut p, make_event("s1", T::ToolUseStart, MAIN, json!({})));
        assert_eq!(p.status(MAIN), AgentStatus::Running);
    }

    #[test]
    fn test_error_event() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::Error, MAIN, json!({})));
        assert_eq!(p.status(MAIN), AgentStatus::Error);
    }

    #[test]
    fn test_prompt_event() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::Prompt, MAIN, json!({})));
        assert_eq!(p.status(MAIN), AgentStatus::Waiting);
    }

    #[test]
    fn test_agent_stop_uses_readable_completion_message() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::AgentStop, MAIN, json!({})));
        assert_eq!(p.last_message(MAIN).as_deref(), Some("Task completed"));
    }

    #[test]
    fn test_status_changed_callback_fires_for_matched_worktree() {
        let mut p = make_provider();
        let out = handle(&mut p, make_event("s1", T::SessionStart, MAIN, json!({})));
        assert_eq!(out.worktree_status, vec![(MAIN.to_string(), AgentStatus::Running)]);
    }

    // MARK: - Agent session resolution

    #[test]
    fn test_agent_session_resolved_fires_for_claude() {
        let mut p = make_provider();
        let r = handle(&mut p, make_event(UUID, T::SessionStart, MAIN, json!({}))).session_ref.unwrap();
        assert_eq!(r.worktree, MAIN);
        assert_eq!(r.session_ref.agent, "claude");
        assert_eq!(r.session_ref.session_id, UUID);
    }

    #[test]
    fn test_agent_session_resolved_excludes_subagent() {
        let mut p = make_provider();
        let out = handle(&mut p, make_event(UUID, T::SubagentStop, MAIN, json!({"agent_id": "sub-1"})));
        assert_eq!(out.session_ref, None);
    }

    #[test]
    fn test_agent_session_resolved_fires_for_codex() {
        let mut p = make_provider();
        let ev = WebhookEvent::new("codex", UUID, T::SessionStart, MAIN, Map::new());
        assert_eq!(handle(&mut p, ev).session_ref.unwrap().session_ref.agent, "codex");
    }

    #[test]
    fn test_agent_session_resolved_skips_unsupported_source() {
        let mut p = make_provider();
        let ev = WebhookEvent::new("gemini", UUID, T::SessionStart, MAIN, Map::new());
        assert_eq!(handle(&mut p, ev).session_ref, None);
    }

    #[test]
    fn test_agent_session_resolved_skips_invalid_session_id() {
        let mut p = make_provider();
        assert_eq!(handle(&mut p, make_event("bad id", T::SessionStart, MAIN, json!({}))).session_ref, None);
    }

    #[test]
    fn test_agent_session_resolved_skips_unknown_worktree() {
        let mut p = make_provider();
        assert_eq!(handle(&mut p, make_event(UUID, T::SessionStart, "/somewhere/else", json!({}))).session_ref, None);
    }

    #[test]
    fn test_codex_user_prompt_falls_back_to_session_lookup() {
        let mut p = make_provider();
        p.set_codex_prompt_lookup(Some(Box::new(|id| {
            assert_eq!(id, "codex-session");
            Some("show me the latest failing test".into())
        })));
        let ev = WebhookEvent::new("codex", "codex-session", T::UserPrompt, MAIN, Map::new());
        handle(&mut p, ev);
        assert_eq!(p.last_user_prompt(MAIN).as_deref(), Some("show me the latest failing test"));
    }

    #[test]
    fn test_claude_user_prompt_does_not_use_codex_fallback() {
        let mut p = make_provider();
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = calls.clone();
        p.set_codex_prompt_lookup(Some(Box::new(move |_| {
            counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Some("should not be used".into())
        })));
        let out = handle(&mut p, make_event("s1", T::UserPrompt, MAIN, json!({"prompt": "fix the dashboard layout"})));
        assert_eq!(p.last_user_prompt(MAIN).as_deref(), Some("fix the dashboard layout"));
        assert_eq!(out.user_prompt.as_deref(), Some("fix the dashboard layout"));
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 0);
    }

    // MARK: - cwd matching

    #[test]
    fn test_exact_cwd_match() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::SessionStart, FEATURE, json!({})));
        assert_eq!(p.status(FEATURE), AgentStatus::Running);
        assert_eq!(p.status(MAIN), AgentStatus::Unknown);
    }

    #[test]
    fn test_prefix_cwd_match() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::SessionStart, "/projects/repo/main/src/lib", json!({})));
        assert_eq!(p.status(MAIN), AgentStatus::Running);
    }

    #[test]
    fn test_unknown_cwd_discarded() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::SessionStart, "/unknown/path", json!({})));
        assert_eq!(p.status(MAIN), AgentStatus::Unknown);
        assert_eq!(p.status(FEATURE), AgentStatus::Unknown);
    }

    // MARK: - Multi-session aggregation

    #[test]
    fn test_multiple_sessions_same_worktree_aggregates() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::AgentStop, MAIN, json!({})));
        handle(&mut p, make_event("s2", T::SessionStart, MAIN, json!({})));
        assert_eq!(p.status(MAIN), AgentStatus::Running);
    }

    #[test]
    fn test_multiple_sessions_both_idle() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::AgentStop, MAIN, json!({})));
        handle(&mut p, make_event("s2", T::AgentStop, MAIN, json!({})));
        assert_eq!(p.status(MAIN), AgentStatus::Idle);
    }

    #[test]
    fn test_sessions_isolated_between_worktrees() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::SessionStart, MAIN, json!({})));
        handle(&mut p, make_event("s2", T::Error, FEATURE, json!({})));
        assert_eq!(p.status(MAIN), AgentStatus::Running);
        assert_eq!(p.status(FEATURE), AgentStatus::Error);
    }

    // MARK: - Notification level mapping

    #[test]
    fn test_notification_error_level() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::Notification, MAIN, json!({"level": "error"})));
        assert_eq!(p.status(MAIN), AgentStatus::Error);
    }

    #[test]
    fn test_notification_warning_level() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::Notification, MAIN, json!({"level": "warning"})));
        assert_eq!(p.status(MAIN), AgentStatus::Waiting);
    }

    #[test]
    fn test_notification_info_level() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::Notification, MAIN, json!({"level": "info"})));
        assert_eq!(p.status(MAIN), AgentStatus::Unknown);
    }

    // MARK: - Path normalization

    #[test]
    fn test_trailing_slash_normalized() {
        let mut p = make_provider();
        p.set_worktrees(&["/projects/repo/main/".into()], 0.0);
        handle(&mut p, make_event("s1", T::SessionStart, MAIN, json!({})));
        assert_eq!(p.status(MAIN), AgentStatus::Running);
        assert_eq!(p.status("/projects/repo/main/"), AgentStatus::Running);
    }

    // MARK: - Worktree cleanup

    #[test]
    fn test_update_worktrees_removes_stale_sessions() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::SessionStart, MAIN, json!({})));
        handle(&mut p, make_event("s2", T::SessionStart, FEATURE, json!({})));
        p.set_worktrees(&[MAIN.into()], 1.0);
        assert_eq!(p.status(MAIN), AgentStatus::Running);
        assert_eq!(p.status(FEATURE), AgentStatus::Unknown);
    }

    #[test]
    fn sessions_silent_for_an_hour_are_pruned() {
        let mut p = make_provider();
        handle(&mut p, make_event("s1", T::SessionStart, MAIN, json!({})));
        p.set_worktrees(&[MAIN.into()], 1.0 + SESSION_TTL + 1.0);
        assert_eq!(p.status(MAIN), AgentStatus::Unknown);
    }

    // WebhookTaskParsingTests

    fn task_provider() -> Provider {
        let mut p = Provider::with_home("/home/me".into());
        p.set_codex_prompt_lookup(None);
        p.set_resolve_symlinks(false);
        p.set_worktrees(&["/tmp/project".into()], 0.0);
        p
    }

    fn task_create(subject: &str) -> WebhookEvent {
        make_event(
            "sess1",
            T::ToolUseEnd,
            "/tmp/project",
            json!({"tool_name": "TaskCreate", "tool_input": {"subject": subject, "description": "test"}}),
        )
    }

    fn task_update(id: &str, status: &str) -> WebhookEvent {
        make_event("sess1", T::ToolUseEnd, "/tmp/project", json!({"tool_name": "TaskUpdate", "tool_input": {"taskId": id, "status": status}}))
    }

    #[test]
    fn test_task_create_adds_item() {
        let mut p = task_provider();
        let out = handle(&mut p, task_create("Add tests"));
        let tasks = p.tasks("/tmp/project");
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].subject, "Add tests");
        assert_eq!(tasks[0].status, TaskItemStatus::Pending);
        assert_eq!(tasks[0].id, "1");
        assert_eq!(out.tasks, Some(tasks));
    }

    #[test]
    fn test_multiple_tasks_get_incrementing_ids() {
        let mut p = task_provider();
        for s in ["Task A", "Task B", "Task C"] {
            handle(&mut p, task_create(s));
        }
        assert_eq!(p.tasks("/tmp/project").iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), vec!["1", "2", "3"]);
    }

    #[test]
    fn test_task_update_changes_status() {
        let mut p = task_provider();
        handle(&mut p, task_create("Write code"));
        handle(&mut p, task_update("1", "in_progress"));
        assert_eq!(p.tasks("/tmp/project")[0].status, TaskItemStatus::InProgress);
    }

    #[test]
    fn test_task_update_to_completed() {
        let mut p = task_provider();
        handle(&mut p, task_create("Write code"));
        handle(&mut p, task_update("1", "completed"));
        assert_eq!(p.tasks("/tmp/project")[0].status, TaskItemStatus::Completed);
    }

    #[test]
    fn test_agent_stop_clears_tasks() {
        let mut p = task_provider();
        handle(&mut p, task_create("Write code"));
        handle(&mut p, make_event("sess1", T::AgentStop, "/tmp/project", json!({"stop_reason": "end_turn"})));
        assert!(p.tasks("/tmp/project").is_empty());
    }

    #[test]
    fn test_no_tasks_for_unknown_worktree() {
        let mut p = task_provider();
        handle(&mut p, task_create("Write code"));
        assert!(p.tasks("/tmp/other").is_empty());
    }

    #[test]
    fn test_non_task_tool_use_ignored() {
        let mut p = task_provider();
        handle(&mut p, make_event("sess1", T::ToolUseEnd, "/tmp/project", json!({"tool_name": "Bash", "tool_input": {"command": "ls"}})));
        assert!(p.tasks("/tmp/project").is_empty());
    }

    // AgentMovedWorktreeTests — against real directories, as the Swift ran them.

    struct Fixture {
        _dir: tempfile::TempDir,
        root: PathBuf,
    }

    impl Fixture {
        fn new() -> Self {
            let dir = tempfile::tempdir().unwrap();
            let root = dir.path().to_path_buf();
            Fixture { _dir: dir, root }
        }

        fn path(&self, rel: &str) -> String {
            self.root.join(rel).to_string_lossy().into_owned()
        }

        fn dir(&self, rel: &str) -> String {
            std::fs::create_dir_all(self.root.join(rel)).unwrap();
            self.path(rel)
        }

        /// A linked worktree root: a directory holding a `.git` *file*.
        fn worktree_root(&self, rel: &str) -> String {
            let p = self.dir(rel);
            std::fs::write(self.root.join(rel).join(".git"), "gitdir: /elsewhere\n").unwrap();
            p
        }
    }

    /// The normalization the provider applies to both sides.
    fn canon(p: &str) -> String {
        std::fs::canonicalize(p).map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|_| p.to_string())
    }

    fn moved_event(cwd: &str, pane: Option<&str>) -> WebhookEvent {
        let mut e = make_event("s1", T::ToolUseEnd, cwd, json!({"tool_name": "Bash"}));
        e.pane_id = pane.map(str::to_string);
        e
    }

    fn bash_event(cwd: &str, command: &str) -> WebhookEvent {
        let mut e = make_event("s1", T::ToolUseStart, cwd, json!({"tool_name": "Bash", "tool_input": {"command": command}}));
        e.pane_id = Some("seahelm-repo-main".into());
        e
    }

    fn fs_provider(worktrees: &[String]) -> Provider {
        let mut p = Provider::with_home("/home/me".into());
        p.set_codex_prompt_lookup(None);
        p.set_worktrees(worktrees, 0.0);
        p
    }

    fn fs_handle(p: &mut Provider, ev: &WebhookEvent, now: Timestamp) -> Output {
        p.handle(ev, now, &mut |path: &str| probe_worktree_root(path))
    }

    const PANE: Option<&str> = Some("seahelm-repo-main");

    #[test]
    fn test_worktree_nested_inside_a_known_one_is_detected() {
        let f = Fixture::new();
        let repo = f.dir("repo");
        let nested = f.worktree_root("repo/.claude/worktrees/feature");
        let mut p = fs_provider(&[repo]);
        let out = fs_handle(&mut p, &moved_event(&nested, PANE), 1.0);
        assert_eq!(out.new_worktree, Some((canon(&nested), Some("seahelm-repo-main".into()))));
    }

    #[test]
    fn test_plain_subdirectory_is_not_treated_as_a_worktree() {
        let f = Fixture::new();
        let repo = f.dir("repo");
        let subdir = f.dir("repo/Sources/Core");
        let mut p = fs_provider(&[repo]);
        assert_eq!(fs_handle(&mut p, &moved_event(&subdir, PANE), 1.0).new_worktree, None);
    }

    #[test]
    fn test_completely_unknown_path_is_still_reported() {
        let f = Fixture::new();
        let repo = f.dir("repo");
        let sibling = f.dir("repo-worktrees/feature");
        let mut p = fs_provider(&[repo]);
        let out = fs_handle(&mut p, &moved_event(&sibling, PANE), 1.0);
        assert_eq!(out.new_worktree.map(|(path, _)| path), Some(canon(&sibling)));
    }

    #[test]
    fn test_nested_worktree_wins_over_its_parent() {
        let f = Fixture::new();
        let repo = f.dir("repo");
        let nested = f.worktree_root("repo/.claude/worktrees/feature");
        let p = fs_provider(&[repo.clone(), nested.clone()]);
        assert_eq!(p.match_worktree(&canon(&nested)), Some(canon(&nested)));
        assert_eq!(p.match_worktree(&format!("{}/Sources", canon(&nested))), Some(canon(&nested)));
        assert_eq!(p.match_worktree(&format!("{}/Sources", canon(&repo))), Some(canon(&repo)));
    }

    #[test]
    fn test_repeated_events_ask_for_discovery_once() {
        let f = Fixture::new();
        let repo = f.dir("repo");
        let nested = f.worktree_root("repo/.claude/worktrees/feature");
        let mut p = fs_provider(&[repo]);
        let calls = (0..5).filter(|i| fs_handle(&mut p, &moved_event(&nested, PANE), 1.0 + *i as f64).new_worktree.is_some()).count();
        assert_eq!(calls, 1, "discovery was requested {calls} times for one worktree");
        // The throttle lapses: an agent still there 15 s on asks again.
        assert!(fs_handle(&mut p, &moved_event(&nested, PANE), 17.0).new_worktree.is_some());
    }

    #[test]
    fn test_missing_pane_id_still_reports_the_worktree() {
        let f = Fixture::new();
        let repo = f.dir("repo");
        let nested = f.worktree_root("repo/.claude/worktrees/feature");
        let mut p = fs_provider(&[repo]);
        let out = fs_handle(&mut p, &moved_event(&nested, None), 1.0);
        assert_eq!(out.new_worktree.map(|(_, pane)| pane), Some(None));
    }

    #[test]
    fn test_every_event_reports_the_panes_current_worktree() {
        let f = Fixture::new();
        let repo = f.dir("repo");
        let other = f.worktree_root("repo-worktrees/feature");
        let mut p = fs_provider(&[repo, other.clone()]);
        let loc = fs_handle(&mut p, &moved_event(&other, PANE), 1.0).pane_location.unwrap();
        assert_eq!(loc.pane, "seahelm-repo-main");
        assert_eq!(loc.worktree, Some(canon(&other)));
    }

    #[test]
    fn test_leading_cd_in_a_bash_call_reports_the_worktree_it_went_to() {
        let f = Fixture::new();
        let repo = f.dir("repo");
        let sibling = f.worktree_root("repo-feature");
        let mut p = fs_provider(&[repo.clone(), sibling.clone()]);
        let reported: Vec<Option<String>> = [
            bash_event(&repo, &format!("cd {sibling} && git status")),
            moved_event(&repo, PANE),
            bash_event(&repo, "git log -1"),
        ]
        .iter()
        .map(|e| fs_handle(&mut p, e, 1.0).pane_location.unwrap().worktree)
        .collect();
        assert_eq!(reported, vec![Some(canon(&sibling)), Some(canon(&sibling)), Some(canon(&repo))]);
    }

    #[test]
    fn test_a_worktree_the_panes_agent_created_is_flagged() {
        let f = Fixture::new();
        let repo = f.dir("repo");
        let made = f.worktree_root("repo-made");
        let other = f.worktree_root("repo-other");
        let mut p = fs_provider(&[repo.clone(), made.clone(), other.clone()]);
        let flags = Rc::new(RefCell::new(HashMap::new()));
        for e in [
            bash_event(&repo, "git worktree add -q -b feat/x ../repo-made origin/main"),
            bash_event(&repo, &format!("cd {made} && git status")),
            bash_event(&repo, &format!("cd {other} && git status")),
        ] {
            let loc = fs_handle(&mut p, &e, 1.0).pane_location.unwrap();
            if let Some(w) = loc.worktree {
                flags.borrow_mut().insert(w, loc.created_by_agent);
            }
        }
        assert_eq!(flags.borrow().get(&canon(&made)), Some(&true));
        assert_eq!(flags.borrow().get(&canon(&other)), Some(&false));
    }

    #[test]
    fn test_subagent_events_do_not_report_a_pane_move() {
        let f = Fixture::new();
        let repo = f.dir("repo");
        let mut p = fs_provider(std::slice::from_ref(&repo));
        let mut e = make_event("s1", T::ToolUseEnd, &repo, json!({"tool_name": "Bash", "agent_id": "sub-1"}));
        e.pane_id = Some("seahelm-repo-main".into());
        assert_eq!(fs_handle(&mut p, &e, 1.0).pane_location, None);
    }

    #[test]
    fn test_event_without_a_pane_id_reports_no_move() {
        let f = Fixture::new();
        let repo = f.dir("repo");
        let mut p = fs_provider(std::slice::from_ref(&repo));
        assert_eq!(fs_handle(&mut p, &moved_event(&repo, None), 1.0).pane_location, None);
    }

    #[test]
    fn test_the_signal_repeats_rather_than_firing_once() {
        let f = Fixture::new();
        let repo = f.dir("repo");
        let mut p = fs_provider(std::slice::from_ref(&repo));
        let calls = (0..2).filter(|_| fs_handle(&mut p, &moved_event(&repo, PANE), 1.0).pane_location.is_some()).count();
        assert_eq!(calls, 2);
    }

    #[test]
    fn test_unmatched_cwd_still_reports_pane_location() {
        let f = Fixture::new();
        let elsewhere = f.dir("elsewhere");
        let mut p = fs_provider(&[]);
        let loc = fs_handle(&mut p, &moved_event(&elsewhere, PANE), 1.0).pane_location.unwrap();
        assert_eq!(loc.worktree, None);
        assert_eq!(canon(&loc.location), canon(&elsewhere));
    }

    #[test]
    fn worktree_root_probe_is_only_asked_inside_a_known_worktree() {
        let mut p = make_provider();
        let mut asked = Vec::new();
        let ev = moved_event("/projects/repo/main/src", PANE);
        p.handle(&ev, 1.0, &mut |path: &str| {
            asked.push(path.to_string());
            false
        });
        let ev = moved_event(MAIN, PANE);
        p.handle(&ev, 1.0, &mut |path: &str| {
            asked.push(path.to_string());
            false
        });
        assert_eq!(asked, vec!["/projects/repo/main/src".to_string()]);
    }
}
