//! What the core does to panes and worktrees itself: the calls First Mate
//! makes (`pane.read`, `pane.run`, `pane.send_text`, `pane.send_keys`,
//! `worktree.create`, `worktree.delete`), which any client may make too.
//! All blocking (seahelmd, git); called without the core's lock held.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{json, Value};

use seahelm_core_registry::Registration;
use seahelm_core_types::AgentType;
use seahelmd::proto::Msg;

use crate::core::Core;
use crate::first_mate::facts::git;
use crate::rpc::{RpcError, RpcResult};

const SUBMIT_DELAY: Duration = Duration::from_millis(80);

fn s(p: &Value, k: &str) -> String {
    p.get(k).and_then(Value::as_str).unwrap_or_default().trim().to_string()
}

/// A pane by the core's key, a client alias, or a live session name.
fn pane(core: &Core, p: &Value) -> Result<String, RpcError> {
    let hint = s(p, "pane_id");
    if hint.is_empty() {
        return Err(RpcError::invalid_params("pane_id required"));
    }
    if let Some(id) = core.resolve_pane(&hint) {
        return Ok(id);
    }
    if seahelmd::client::connect(&hint).is_ok() {
        return Ok(hint);
    }
    Err(RpcError::pane_not_found(&hint))
}

fn send(session: &str, bytes: &[u8]) -> Result<(), RpcError> {
    seahelmd::client::request(session, &Msg::Send(bytes.to_vec()))
        .map(|_| ())
        .map_err(|e| RpcError::internal(format!("{session}: {e}")))
}

/// `source: "visible"` (the app's default, and what `seahelm pane read`
/// sends) is the screen as it stands, from seahelmd's snapshot, as the app
/// reads its surface; `"recent"` / `"history"` the scrollback's tail. With
/// no `source` (First Mate's calls) the scrollback's last 200 lines.
pub fn pane_read(core: &Core, p: &Value) -> RpcResult {
    let id = pane(core, p)?;
    let source = s(p, "source");
    let default_lines = if source.is_empty() { 200 } else { 100 };
    let lines = p.get("lines").and_then(Value::as_u64).unwrap_or(default_lines) as usize;
    let text = match source.as_str() {
        "" | "recent" | "history" | "scrollback" => history(&id)?,
        _ => viewport(&id)?,
    };
    Ok(json!({"pane_id": id, "text": tail(&text, lines)}))
}

/// The last `lines` lines (all of them for 0), trailing blank rows dropped.
fn tail(text: &str, lines: usize) -> String {
    let all: Vec<&str> = text.trim_end().lines().collect();
    let from = if lines == 0 { 0 } else { all.len().saturating_sub(lines) };
    all[from..].join("\n")
}

fn history(id: &str) -> Result<String, RpcError> {
    match seahelmd::client::request(id, &Msg::History) {
        Ok(Msg::Text(t)) => Ok(t),
        Ok(_) => Ok(String::new()),
        Err(e) => Err(RpcError::internal(format!("{id}: {e}"))),
    }
}

/// The screen as seahelmd holds it (`snapshot`'s `viewport`).
fn viewport(id: &str) -> Result<String, RpcError> {
    match seahelmd::client::request(id, &Msg::Snapshot) {
        Ok(Msg::Text(t)) => Ok(serde_json::from_str::<Value>(&t)
            .ok()
            .and_then(|v| v.get("viewport").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_default()),
        Ok(_) => Ok(String::new()),
        Err(e) => Err(RpcError::internal(format!("{id}: {e}"))),
    }
}

const WAIT_POLL: Duration = Duration::from_millis(150);
const WAIT_DEFAULT_MS: u64 = 30_000;
const WAIT_MAX_MS: u64 = 600_000;

/// `timeout_ms` as the app reads it: 30 s by default, at most 10 minutes.
pub fn wait_timeout(p: &Value) -> Duration {
    let ms = p.get("timeout_ms").and_then(Value::as_u64).unwrap_or(WAIT_DEFAULT_MS).min(WAIT_MAX_MS);
    Duration::from_millis(ms)
}

/// `wait.output {pane_id, match, regex?, timeout_ms?}`: until the screen
/// shows `match` (a substring, or a regex with `regex: true`), polled as
/// the app polls it. `{matched: true}`, or `{matched: false, timed_out: true}`.
pub fn wait_output(core: &Core, p: &Value) -> RpcResult {
    let id = pane(core, p)?;
    let want = p.get("match").and_then(Value::as_str).unwrap_or_default().to_string();
    if want.is_empty() {
        return Err(RpcError::invalid_params("match required"));
    }
    let re = if p.get("regex").and_then(Value::as_bool) == Some(true) {
        Some(regex::Regex::new(&want).map_err(|_| RpcError::invalid_params(format!("invalid regex: {want}")))?)
    } else {
        None
    };
    let deadline = std::time::Instant::now() + wait_timeout(p);
    loop {
        let screen = viewport(&id)?;
        let hit = match &re {
            Some(re) => re.is_match(&screen),
            None => screen.contains(&want),
        };
        if hit {
            return Ok(json!({"matched": true}));
        }
        if std::time::Instant::now() >= deadline {
            return Ok(json!({"matched": false, "timed_out": true}));
        }
        std::thread::sleep(WAIT_POLL);
    }
}

/// Text typed into a pane, as the app's paste path types it. An AI agent's
/// TUI gets it bracketed (`ESC[200~ … ESC[201~`): typed as bare keys, a long
/// message reached Claude Code cut to its last few dozen characters — the
/// TUI guesses where a fast burst of keys starts and ends, and guessed
/// wrong. Anything else gets the bytes as they are, since nothing says it
/// asked for bracketed paste.
pub fn typed(text: &str, agent: bool) -> Vec<u8> {
    if !agent {
        return text.as_bytes().to_vec();
    }
    // The text cannot end the paste early.
    let body = text.replace("\x1b[201~", "");
    let mut out = b"\x1b[200~".to_vec();
    out.extend_from_slice(body.as_bytes());
    out.extend_from_slice(b"\x1b[201~");
    out
}

pub(crate) fn runs_agent(core: &Core, id: &str) -> bool {
    core.pane_infos().iter().any(|(p, _)| p.id == id && p.agent_type.is_ai_agent())
}

/// Type and submit: the Return as a write of its own, a beat later.
pub fn pane_run(core: &Core, p: &Value) -> RpcResult {
    let id = pane(core, p)?;
    let command = s(p, "command");
    if command.is_empty() {
        return Err(RpcError::invalid_params("command required"));
    }
    send(&id, &typed(&command, runs_agent(core, &id)))?;
    std::thread::sleep(SUBMIT_DELAY);
    send(&id, b"\r")?;
    Ok(json!({"sent": true, "pane_id": id}))
}

pub fn pane_send_text(core: &Core, p: &Value) -> RpcResult {
    let id = pane(core, p)?;
    let text = p.get("text").and_then(Value::as_str).unwrap_or_default();
    if text.is_empty() {
        return Err(RpcError::invalid_params("text required"));
    }
    send(&id, &typed(text, runs_agent(core, &id)))?;
    // `enter: true` submits it, the Return as a write of its own a beat
    // later (as `pane.run`): a TUI reading the text and the Return in one
    // read can take the Return as part of a paste and not submit.
    if p.get("enter").and_then(Value::as_bool).unwrap_or(false) {
        std::thread::sleep(SUBMIT_DELAY);
        send(&id, b"\r")?;
    }
    Ok(json!({"sent": true, "pane_id": id}))
}

pub fn pane_send_keys(core: &Core, p: &Value) -> RpcResult {
    let id = pane(core, p)?;
    let keys: Vec<String> = match p.get("keys") {
        Some(Value::String(k)) => vec![k.clone()],
        Some(Value::Array(a)) => a.iter().filter_map(Value::as_str).map(str::to_string).collect(),
        _ => vec![],
    };
    if keys.is_empty() {
        return Err(RpcError::invalid_params("keys required"));
    }
    // Every key named right before any is pressed: half a sequence is worse
    // than none.
    let all = keys
        .iter()
        .map(|k| crate::keys::bytes(k).ok_or_else(|| RpcError::invalid_params(format!("unknown key {k}"))))
        .collect::<Result<Vec<_>, _>>()?;
    for (i, bytes) in all.iter().enumerate() {
        if bytes == "\r" && i > 0 {
            std::thread::sleep(SUBMIT_DELAY);
        }
        send(&id, bytes.as_bytes())?;
    }
    Ok(json!({"sent": true, "pane_id": id}))
}

/// The session the GPUI client would give a worktree's first pane
/// (`workspace::session_name`), so a pane the core starts is the one that
/// client attaches when the worktree is opened.
pub fn gpui_session_name(worktree: &str) -> String {
    let base = Path::new(worktree).file_name().and_then(|n| n.to_str()).unwrap_or("worktree");
    let mut h: u32 = 2166136261;
    for b in worktree.bytes() {
        h = (h ^ b as u32).wrapping_mul(16777619);
    }
    let clean: String = base.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' }).take(40).collect();
    format!("gpui-{clean}-{h:08x}")
}

/// `task/<slug of the task>`, suffixed past existing branches
/// (`WorktreeCreator.branchName`).
pub fn branch_name(task: &str, existing: &[String]) -> String {
    let mut words: Vec<String> = Vec::new();
    let mut cur = String::new();
    for c in task.to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            cur.push(c);
        } else if !cur.is_empty() {
            words.push(std::mem::take(&mut cur));
        }
    }
    if !cur.is_empty() {
        words.push(cur);
    }
    let mut slug = String::new();
    for w in words.iter().take(6) {
        if slug.len() + w.len() + 1 > 40 {
            break;
        }
        if !slug.is_empty() {
            slug.push('-');
        }
        slug.push_str(w);
    }
    if slug.is_empty() {
        slug = "agent".into();
    }
    let base = format!("task/{slug}");
    if !existing.contains(&base) {
        return base;
    }
    (2..).map(|n| format!("{base}-{n}")).find(|b| !existing.contains(b)).unwrap_or(base)
}

/// The agents a worktree or pane can be started with: the binary and its
/// skip-permissions flag, as the macOS app's `AgentType.launchCommand` /
/// `yoloFlag` have them (Cursor's agent CLI is `agent`, not the IDE shim).
pub fn launch_parts(agent: AgentType) -> Option<(&'static str, Option<&'static str>)> {
    use AgentType::*;
    Some(match agent {
        ClaudeCode => ("claude", Some("--dangerously-skip-permissions")),
        Codex => ("codex", Some("--dangerously-bypass-approvals-and-sandbox")),
        OpenCode => ("opencode", Some("--yolo")),
        Gemini => ("gemini", None),
        Cline => ("cline", None),
        Goose => ("goose", None),
        Amp => ("amp", None),
        Aider => ("aider", None),
        Cursor => ("agent", Some("--yolo")),
        Kiro => ("kiro", None),
        Pi => ("pi", None),
        _ => return None,
    })
}

/// An `agent_type` from the wire (`claudeCode`, `openCode`…) that can be
/// launched; empty is Claude Code.
fn launchable(name: &str) -> Result<AgentType, RpcError> {
    if name.is_empty() {
        return Ok(AgentType::ClaudeCode);
    }
    serde_json::from_value::<AgentType>(json!(name))
        .ok()
        .filter(|a| launch_parts(*a).is_some())
        .ok_or_else(|| RpcError::invalid_params(format!("agent_type {name} cannot be launched")))
}

fn bare_command(agent: AgentType, yolo: bool) -> Option<String> {
    let (bin, flag) = launch_parts(agent)?;
    Some(match flag {
        Some(flag) if yolo => format!("{bin} {flag}"),
        _ => bin.to_string(),
    })
}

/// The agent with its task as the initial prompt, a positional argument,
/// as the macOS app launches every agent.
fn agent_command(agent: AgentType, task: &str, yolo: bool) -> Option<String> {
    Some(format!("{} {}", bare_command(agent, yolo)?, shell_quote(task)))
}

fn shell_quote(s: &str) -> String {
    if cfg!(windows) {
        format!("\"{}\"", s.replace('"', "\\\""))
    } else {
        format!("'{}'", s.replace('\'', r"'\''"))
    }
}

/// `worktree.create {repo_path, prompt, agent_type?}`: a new worktree beside
/// the repo (`<repo>-worktrees/<branch>`) with an agent briefed on the task,
/// in a seahelmd session the core watches. The repo's `.seahelm/setup.sh`
/// runs first, and a failed setup leaves the shell with its error.
pub fn worktree_create(core: &Core, p: &Value) -> RpcResult {
    worktree_create_with_hint(core, p, crate::first_mate::policy::is_first_mate(p))
}

/// Only First Mate's approved execution path calls this entry point.
pub(crate) fn worktree_create_first_mate(core: &Core, p: &Value) -> RpcResult {
    worktree_create_with_hint(core, p, true)
}

fn creation_branch(task: &str, p: &Value, existing: &[String], allow_hint: bool) -> String {
    let hint = s(p, "branch_hint");
    branch_name(
        if allow_hint && !hint.is_empty() {
            &hint
        } else {
            task
        },
        existing,
    )
}

fn worktree_create_with_hint(core: &Core, p: &Value, allow_hint: bool) -> RpcResult {
    let repo = PathBuf::from(s(p, "repo_path"));
    let mut task = s(p, "prompt");
    let main_repo = crate::first_mate::routing::main_repo(&s(p,"repo_path"));
    let pointer = core.memory_store().pointer(&main_repo);
    if !pointer.is_empty() { task.push_str(&format!("\n\n{pointer}")); }
    if repo.as_os_str().is_empty() || s(p, "prompt").is_empty() {
        return Err(RpcError::invalid_params("repo_path and prompt are required"));
    }
    let agent = launchable(&s(p, "agent_type"))?;
    let top = git(&repo, &["rev-parse", "--show-toplevel"]).ok_or_else(|| RpcError::invalid_params("not a git repository"))?;
    let repo = PathBuf::from(top.trim());
    let branches: Vec<String> = git(&repo, &["branch", "-a", "--format=%(refname:short)"])
        .unwrap_or_default()
        .lines()
        .map(|b| b.trim().trim_start_matches("origin/").to_string())
        .filter(|b| !b.is_empty() && !b.contains("HEAD"))
        .collect();
    let base = ["main", "master"].into_iter().find(|b| branches.iter().any(|x| x == b)).map(str::to_string).or_else(|| branches.first().cloned()).unwrap_or_else(|| "main".into());
    let issue = if allow_hint && !s(p,"branch_hint").is_empty() { None } else {
        crate::first_mate::routing::linked_issue(&s(p,"prompt"), &crate::first_mate::routing::remotes(&main_repo))
    };
    let branch_template=core.memory_store().value(&main_repo,"branch naming");
    if let Some((_, n)) = &issue {
        if let Some(existing) = branches.iter().find(|b| crate::first_mate::routing::issue_branch_matches(b, *n,branch_template.as_deref())) {
            return Ok(json!({"existing": existing, "issue": n, "created": false}));
        }
    }
    let branch = if let Some((_, n)) = issue {
        issue_branch(n, &s(p, "prompt"), branch_template.as_deref())
    } else { creation_branch(&s(p, "prompt"), p, &branches, allow_hint) };
    if git(&repo, &["check-ref-format", "--branch", &branch]).is_none() { return Err(RpcError::invalid_params("invalid branch naming convention")); }
    let name = repo.file_name().and_then(|n| n.to_str()).unwrap_or("repo");
    let path = repo.parent().unwrap_or(&repo).join(format!("{name}-worktrees")).join(&branch);
    if path.exists() {
        return Err(RpcError::invalid_params(format!("{} exists", path.display())));
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| RpcError::internal(e.to_string()))?;
    }
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(&repo)
        .args(["worktree", "add", "-b", &branch])
        .arg(&path)
        .arg(&base)
        .output()
        .map_err(|e| RpcError::internal(e.to_string()))?;
    if !out.status.success() {
        return Err(RpcError::internal(format!("git worktree add: {}", String::from_utf8_lossy(&out.stderr).trim())));
    }
    let path_s = path.to_string_lossy().to_string();
    let launch = agent_command(agent, &task, crate::first_mate::UserConfig::load().agent_yolo).unwrap_or_default();
    let setup = [path.join(".seahelm/setup.sh"), repo.join(".seahelm/setup.sh")].into_iter().find(|p| p.exists());
    let session = gpui_session_name(&path_s);
    start_session(&session, &path, setup.as_deref(), &repo, &launch).map_err(RpcError::internal)?;
    core.register_pane(Registration {
        pane: session.clone(),
        alias: None,
        worktree_path: path_s.clone(),
        project: name.to_string(),
        branch: branch.clone(),
        agent_type: agent,
        started_at: Some(seahelm_core_types::now()),
    });
    Ok(json!({"worktree_path": path_s, "branch": branch, "pane_session_key": session}))
}

/// `seahelmd new --hold 15 <session> -- <shell> -lic '<setup> && <agent>; exec <shell> -l'`
/// in the worktree: held for a client to attach, so the agent starts at the
/// pane's size when someone opens it, and on its own after that.
fn start_session(session: &str, dir: &Path, setup: Option<&Path>, repo: &Path, launch: &str) -> Result<(), String> {
    let mut line = String::new();
    if let Some(script) = setup {
        line += &format!("{} && ", shell_quote(&script.to_string_lossy()));
    }
    line += launch;
    let mut cmd = std::process::Command::new(seahelmd_bin());
    cmd.current_dir(dir)
        .env("SEAHELM_WORKTREE", dir)
        .env("SEAHELM_REPO_ROOT", repo)
        .env("SEAHELM_PANE_ID", session)
        .args(["new", "--hold", "15", session, "--"]);
    #[cfg(unix)]
    {
        let shell = std::env::var("SHELL").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/bin/sh".into());
        cmd.args([shell.as_str(), "-lic", &format!("{line}; exec {} -l", shell_quote(&shell))]);
    }
    #[cfg(windows)]
    cmd.args(["cmd.exe", "/k", &line]);
    let out = cmd.output().map_err(|e| format!("seahelmd new: {e}"))?;
    if !out.status.success() {
        return Err(format!("seahelmd new: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(())
}

/// `$SEAHELMD_BIN`, then `seahelmd` beside this binary, then on PATH.
pub fn seahelmd_bin() -> PathBuf {
    if let Some(p) = std::env::var_os("SEAHELMD_BIN").filter(|p| !p.is_empty()) {
        return PathBuf::from(p);
    }
    let exe = format!("seahelmd{}", std::env::consts::EXE_SUFFIX);
    std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(|d| d.join(&exe)))
        .filter(|p| p.exists())
        .unwrap_or_else(|| PathBuf::from(exe))
}

/// `worktree.delete {worktree_path}`: its panes' sessions killed, then
/// `git worktree remove` without force, so a worktree with uncommitted work
/// stays and the caller hears why. The branch is left.
pub fn worktree_delete(core: &Core, p: &Value) -> RpcResult {
    let path = s(p, "worktree_path");
    if path.is_empty() {
        return Err(RpcError::invalid_params("worktree_path required"));
    }
    let dir = Path::new(&path);
    let common = git(dir, &["rev-parse", "--path-format=absolute", "--git-common-dir"]).ok_or_else(|| RpcError::invalid_params("not a worktree"))?;
    let main = Path::new(common.trim()).parent().map(Path::to_path_buf).unwrap_or_default();
    if same_dir(&main, dir) {
        return Err(RpcError::invalid_params("the main checkout is not deleted"));
    }
    // `git worktree remove` refuses a worktree with uncommitted work; ask
    // first, so a refusal leaves its sessions (and the agents in them)
    // running instead of ending them for nothing.
    let dirty = git(dir, &["status", "--porcelain"]).map(|s| s.lines().filter(|l| !l.trim().is_empty()).count()).unwrap_or(0);
    if dirty > 0 {
        return Err(RpcError::invalid_params(format!(
            "{dirty} uncommitted change{} in {path}: commit or discard them first",
            if dirty == 1 { "" } else { "s" }
        )));
    }
    let mut sessions = core.panes_in_worktree(&path);
    let own = gpui_session_name(&path);
    if !sessions.contains(&own) {
        sessions.push(own);
    }
    for session in &sessions {
        let _ = seahelmd::client::request(session, &Msg::Kill);
        core.unregister_pane(session);
    }
    let remove = |force: bool| {
        let mut cmd = std::process::Command::new("git");
        cmd.arg("-C").arg(&main).args(["worktree", "remove"]);
        if force {
            cmd.arg("--force");
        }
        cmd.arg(dir).output().map_err(|e| RpcError::internal(e.to_string()))
    };
    let mut out = remove(false)?;
    // git refuses any worktree with an initialised submodule unless forced,
    // clean or not. `git status` above already covers the submodules (their
    // changes, new commits and untracked content), so a clean tree is safe
    // to force; ask again in case something was written since.
    if !out.status.success() && refuses_for_submodules(&String::from_utf8_lossy(&out.stderr)) && is_clean(dir) {
        out = remove(true)?;
    }
    if !out.status.success() {
        return Err(RpcError::internal(format!("git worktree remove: {}", String::from_utf8_lossy(&out.stderr).trim())));
    }
    core.clear_worktree_cards(&path);
    Ok(json!({"worktree_path": path, "deleted": true}))
}

/// `git worktree remove`'s refusal of a worktree that has initialised
/// submodules, which it gives whether or not the tree is clean.
fn refuses_for_submodules(stderr: &str) -> bool {
    stderr.contains("containing submodules cannot be moved or removed")
}

fn is_clean(dir: &Path) -> bool {
    git(dir, &["status", "--porcelain"]).is_some_and(|s| s.trim().is_empty())
}

fn same_dir(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agents_get_text_as_one_bracketed_paste() {
        assert_eq!(typed("ls -la", false), b"ls -la".to_vec());
        assert_eq!(typed("给运动场馆\n\n[seahelm projects] []", true), "\x1b[200~给运动场馆\n\n[seahelm projects] []\x1b[201~".as_bytes().to_vec());
        // A paste end inside the text is dropped, so it cannot end the paste.
        assert_eq!(typed("a\x1b[201~b", true), b"\x1b[200~ab\x1b[201~".to_vec());
    }

    #[test]
    fn branch_hints_require_first_mate_execution() {
        let params = json!({"branch_hint":"12 login","_task":{"key":"#12"}});
        assert_eq!(
            creation_branch("ordinary task", &params, &[], false),
            branch_name("ordinary task", &[])
        );
        assert_eq!(
            creation_branch("ordinary task", &params, &[], true),
            branch_name("12 login", &[])
        );
    }

    #[test]
    fn every_agent_the_macos_app_launches_can_be_started() {
        for (wire, cmd) in [
            ("", "claude"),
            ("claudeCode", "claude"),
            ("codex", "codex"),
            ("openCode", "opencode"),
            ("gemini", "gemini"),
            ("cursor", "agent"),
            ("pi", "pi"),
        ] {
            let agent = launchable(wire).unwrap();
            assert_eq!(bare_command(agent, false).as_deref(), Some(cmd), "{wire}");
        }
        assert_eq!(bare_command(AgentType::OpenCode, true).as_deref(), Some("opencode --yolo"));
        assert_eq!(bare_command(AgentType::Gemini, true).as_deref(), Some("gemini"), "no flag known");
        assert!(launchable("npm").is_err());
        assert!(launchable("nonsense").is_err());
        if !cfg!(windows) {
            assert_eq!(agent_command(AgentType::Aider, "fix it", false).as_deref(), Some("aider 'fix it'"));
        }
    }

    #[test]
    fn branch_names_from_tasks() {
        assert_eq!(branch_name("Fix the login 500 on /api/session!", &[]), "task/fix-the-login-500-on-api");
        assert_eq!(branch_name("修复登录", &[]), "task/agent");
        let taken = vec!["task/fix-ci".to_string(), "task/fix-ci-2".to_string()];
        assert_eq!(branch_name("fix ci", &taken), "task/fix-ci-3");
    }

    #[test]
    fn session_names_match_the_gpui_clients() {
        // What workspace::session_name gives for the same path.
        assert_eq!(gpui_session_name("/w/repo"), "gpui-repo-cc861fb8");
        assert!(gpui_session_name("/w/task/a b").starts_with("gpui-a_b-"));
    }

    #[test]
    fn tails_count_lines_from_the_end() {
        assert_eq!(tail("a\nb\nc\n\n", 2), "b\nc");
        assert_eq!(tail("a\nb", 0), "a\nb");
        assert_eq!(tail("a\nb", 9), "a\nb");
    }

    #[test]
    fn wait_timeouts_read_as_the_apps() {
        assert_eq!(wait_timeout(&json!({})), Duration::from_secs(30));
        assert_eq!(wait_timeout(&json!({"timeout_ms": 1500})), Duration::from_millis(1500));
        assert_eq!(wait_timeout(&json!({"timeout_ms": 9_000_000})), Duration::from_secs(600));
    }
}

/// `worktree.options`: what a remote "new worktree" form offers — the repos
/// of the worktrees clients list, and the agents on PATH.
pub fn worktree_options(core: &Core) -> Value {
    let mut repos: Vec<Value> = core
        .repos()
        .into_iter()
        .map(|path| {
            let name = Path::new(&path).file_name().and_then(|n| n.to_str()).unwrap_or(&path).to_string();
            json!({"name": name, "path": path})
        })
        .collect();
    repos.sort_by_key(|r| r["name"].as_str().unwrap_or("").to_lowercase());
    let agents: Vec<Value> = [("claudeCode", "claude", "Claude Code"), ("codex", "codex", "Codex")]
        .into_iter()
        .filter(|(_, bin, _)| on_path(bin))
        .map(|(id, _, label)| json!({"id": id, "label": label}))
        .collect();
    json!({"repos": repos, "agents": agents})
}

fn on_path(bin: &str) -> bool {
    let exe = format!("{bin}{}", std::env::consts::EXE_SUFFIX);
    std::env::var_os("PATH").is_some_and(|paths| std::env::split_paths(&paths).any(|d| d.join(&exe).is_file()))
}

/// `pane.new {worktree_path | pane_session_key, agent_type?}`: a new
/// session in that worktree (the user's shell, or the agent), registered
/// here. Where it goes on screen is up to whoever draws the worktree: the
/// app files it as a new split leaf when it hears `pane.registered`.
pub fn pane_new(core: &Core, p: &Value) -> RpcResult {
    let mut worktree = s(p, "worktree_path");
    let mut like: Option<Value> = None;
    if worktree.is_empty() {
        let hint = s(p, "pane_session_key");
        let hint = if hint.is_empty() { s(p, "pane_id") } else { hint };
        let pane = core.resolve_pane(&hint).ok_or_else(|| RpcError::invalid_params("worktree_path or a known pane required"))?;
        like = core.pane_row(&pane);
        worktree = like.as_ref().and_then(|r| r["worktree_path"].as_str()).unwrap_or_default().to_string();
    }
    let dir = PathBuf::from(&worktree);
    if worktree.is_empty() || !dir.is_dir() {
        return Err(RpcError::invalid_params("no such worktree"));
    }
    if like.is_none() {
        like = core.panes_in_worktree(&worktree).first().and_then(|k| core.pane_row(k));
    }
    let agent = match s(p, "agent_type").as_str() {
        "" | "shell" => None,
        other => Some(launchable(other)?),
    };
    let base = gpui_session_name(&worktree);
    let session = (2..1000)
        .map(|n| format!("{base}-{n}"))
        .find(|name| core.pane_row(name).is_none() && seahelmd::client::socket_path(name).map(|p| !p.exists()).unwrap_or(false))
        .ok_or_else(|| RpcError::internal("no free session name"))?;
    let launch = agent.and_then(|a| bare_command(a, crate::first_mate::UserConfig::load().agent_yolo));
    start_plain_session(&session, &dir, launch.as_deref()).map_err(RpcError::internal)?;
    let field = |k: &str| like.as_ref().and_then(|r| r[k].as_str()).unwrap_or_default().to_string();
    let project = Some(field("project")).filter(|p| !p.is_empty()).unwrap_or_else(|| {
        git(&dir, &["rev-parse", "--path-format=absolute", "--git-common-dir"])
            .and_then(|c| Path::new(c.trim()).parent().and_then(|r| r.file_name()).map(|n| n.to_string_lossy().into_owned()))
            .unwrap_or_default()
    });
    core.register_pane(Registration {
        pane: session.clone(),
        alias: None,
        worktree_path: worktree.clone(),
        project,
        branch: field("branch"),
        agent_type: agent.unwrap_or_default(),
        started_at: Some(seahelm_core_types::now()),
    });
    Ok(json!({"pane_session_key": session, "worktree_path": worktree}))
}

/// The user's login shell, or `<agent>; exec <shell> -l`, held for a client.
fn start_plain_session(session: &str, dir: &Path, launch: Option<&str>) -> Result<(), String> {
    let mut cmd = std::process::Command::new(seahelmd_bin());
    cmd.current_dir(dir).env("SEAHELM_PANE_ID", session).args(["new", "--hold", "15", session, "--"]);
    #[cfg(unix)]
    {
        let shell = std::env::var("SHELL").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/bin/sh".into());
        match launch {
            Some(l) => cmd.args([shell.as_str(), "-lic", &format!("{l}; exec {} -l", shell_quote(&shell))]),
            None => cmd.args([shell.as_str(), "-l"]),
        };
    }
    #[cfg(windows)]
    match launch {
        Some(l) => cmd.args(["cmd.exe", "/k", l]),
        None => cmd.args(["cmd.exe"]),
    };
    let out = cmd.output().map_err(|e| format!("seahelmd new: {e}"))?;
    if !out.status.success() {
        return Err(format!("seahelmd new: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(())
}

/// `pane.close {pane}`: its session ended and the pane forgotten, with
/// `pane.closed {by_request: true}` so the client drawing it removes it.
pub fn pane_close(core: &Core, p: &Value) -> RpcResult {
    let hint = ["pane", "pane_session_key", "pane_id"].iter().map(|k| s(p, k)).find(|h| !h.is_empty()).ok_or_else(|| RpcError::invalid_params("pane required"))?;
    let pane = core.resolve_pane(&hint).ok_or_else(|| RpcError::invalid_params("unknown pane"))?;
    if pane == crate::first_mate::policy::SESSION {
        return Err(RpcError::invalid_params("First Mate's session is not closed this way"));
    }
    let _ = seahelmd::client::request(&pane, &Msg::Kill);
    core.close_pane(&pane);
    Ok(json!({"closed": true, "pane_session_key": pane}))
}

/// A user-learned template from project memory, otherwise the issue default.
fn issue_branch(n: u64, task: &str, template: Option<&str>) -> String {
    let slug = branch_name(task, &[]).trim_start_matches("task/").to_string();
    template.unwrap_or("fix/{n}-{slug}").replace("{n}", &n.to_string()).replace("{slug}", &slug)
}
#[cfg(test)]
mod issue_branch_tests {
    use super::*;
    #[test]
    fn learned_branch_template_dedupes_before_creating_or_launching() {
        let tmp=tempfile::tempdir().unwrap(); let repo=tmp.path().join("repo"); std::fs::create_dir(&repo).unwrap();
        for args in [vec!["init","-b","main"],vec!["-c","user.name=Test","-c","user.email=test@example.invalid","commit","--allow-empty","-m","init"],vec!["remote","add","origin","https://github.com/o/r.git"],vec!["branch","bug/42-login"]] {
            assert!(std::process::Command::new("git").arg("-C").arg(&repo).args(args).output().unwrap().status.success());
        }
        let core=Core::for_test(tmp.path());
        let root=crate::first_mate::routing::main_repo(repo.to_str().unwrap());
        core.memory_store().note(&root,"branch naming: bug/{n}-{slug}","user").unwrap();
        let result=worktree_create(&core,&json!({"repo_path":repo,"prompt":"https://github.com/o/r/issues/42 login"})).unwrap();
        assert_eq!(result["created"],false); assert_eq!(result["existing"],"bug/42-login");
        assert!(core.live_worktrees().is_empty());
    }

    #[test]
    fn a_clean_worktree_with_an_initialised_submodule_is_deleted_and_a_dirty_one_is_not() {
        let tmp = tempfile::tempdir().unwrap();
        let run = |dir: &Path, args: &[&str]| {
            let out = std::process::Command::new("git").arg("-C").arg(dir)
                .args(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "protocol.file.allow=always"])
                .args(args).output().unwrap();
            assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        };
        let (sub, repo) = (tmp.path().join("sub"), tmp.path().join("repo"));
        for d in [&sub, &repo] {
            std::fs::create_dir(d).unwrap();
            run(d, &["init", "-q", "-b", "main"]);
            run(d, &["commit", "-q", "--allow-empty", "-m", "init"]);
        }
        run(&repo, &["submodule", "add", "-q", sub.to_str().unwrap(), "sub"]);
        run(&repo, &["commit", "-q", "-m", "submodule"]);
        let core = Core::for_test(tmp.path());
        for name in ["clean", "dirty"] {
            let wt = tmp.path().join(name);
            run(&repo, &["worktree", "add", "-q", "-b", name, wt.to_str().unwrap()]);
            run(&wt, &["submodule", "update", "-q", "--init"]);
        }
        std::fs::write(tmp.path().join("dirty/sub/scratch.txt"), "x").unwrap();

        let clean = tmp.path().join("clean");
        assert_eq!(worktree_delete(&core, &json!({"worktree_path": clean})).unwrap()["deleted"], true);
        assert!(!clean.exists());
        let dirty = tmp.path().join("dirty");
        assert!(worktree_delete(&core, &json!({"worktree_path": dirty})).is_err(), "untracked content in a submodule is work");
        assert!(dirty.join("sub/scratch.txt").exists());
    }

    #[test] fn issue_branch_uses_the_learned_template_or_default() {
        assert_eq!(issue_branch(42, "login crashes", None), "fix/42-login-crashes");
        assert_eq!(issue_branch(42, "login crashes", Some("bug/{n}/{slug}")), "bug/42/login-crashes");
    }
}
