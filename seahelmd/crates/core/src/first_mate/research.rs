//! Project-less research jobs. Only peer-checked schedule RPCs grant a job;
//! matching a hand-edited file alone never grants an agent start (D31–D34).
use super::{budget, lang::Text, policy, Action, Cron, FirstMate, Level, Local};
use crate::rpc::{RpcError, RpcResult};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    process::Command,
};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Budget {
    pub max_minutes: u32,
    pub pause_above_usage: f64,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Job {
    pub name: String,
    pub cron: String,
    pub brief: String,
    pub enabled: bool,
    pub budget: Budget,
}
impl Job {
    pub fn validate(&self) -> bool {
        !self.name.is_empty()
            && self.name.len() <= 80
            && self.name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            && Cron::parse(&self.cron).is_some()
            && !self.brief.trim().is_empty()
            && self.budget.max_minutes > 0
            && self.budget.max_minutes <= 1440
            && self.budget.pause_above_usage.is_finite()
            && (0.0..=100.0).contains(&self.budget.pause_above_usage)
    }
}
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Run {
    name: String,
    worktree: String,
    session: String,
    path: String,
    started: f64,
    #[serde(default)]
    baseline: String,
    minutes: u32,
    commit: Option<String>,
    summary: Option<String>,
    delivered: bool,
    opened: bool,
    proposed: bool,
    #[serde(default)]
    timed_out: bool,
    #[serde(default)]
    notified_at: f64,
    #[serde(default)]
    finished: bool,
    #[serde(default)]
    cleaned: bool,
    #[serde(default)]
    notified_failure: bool,
    #[serde(default)]
    attempts: u32,
    #[serde(default)]
    branch: String,
    #[serde(default)]
    cleanup_stopped: bool,
}
pub const MAX_RESEARCH_RUNS: usize = 1;
const DEADLINE_GRACE: f64 = 30.0;
const SUMMARY_ATTEMPTS: u32 = 3;
const LAUNCH_TIMEOUT: f64 = 120.0;

#[derive(Default, Serialize, Deserialize)]
pub struct State {
    approved: Vec<Job>,
    runs: Vec<Run>,
    last_minute: Option<i64>,
    #[serde(default)]
    bad_schedule_text: Option<String>,
    #[serde(default)]
    offered: BTreeMap<String, usize>,
    #[serde(default)]
    completed: BTreeMap<String, usize>,
}
impl State {
    fn take_minute(&mut self, now: f64) -> bool {
        let minute = (now / 60.0).floor() as i64;
        if self.last_minute == Some(minute) {
            return false;
        }
        self.last_minute = Some(minute);
        true
    }
    pub fn load(dir: &Path) -> Self {
        std::fs::read(dir.join("research.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }
    pub fn save(&self, dir: &Path) {
        let path = dir.join("research.json");
        let text = serde_json::to_string_pretty(self).unwrap();
        if std::fs::read_to_string(&path).ok().as_deref() != Some(&text) {
            let _ = write(&path, &text);
        }
    }
    pub fn followup(&mut self, text: &str) {
        for r in &mut self.runs {
            if text.contains(&r.worktree) || text.contains(&r.path) || text.contains(&r.name) {
                r.opened = true;
            }
        }
    }
    pub fn seen(&mut self, paths: &[String]) {
        for r in &mut self.runs {
            if paths.contains(&r.worktree) {
                r.opened = true;
            }
        }
    }
    fn offer_due(&mut self, name: &str, unread: usize) -> bool {
        let evidence = *self.completed.get(name).unwrap_or(&0);
        if unread < 3 || self.offered.get(name).is_some_and(|last| evidence <= *last) {
            return false;
        }
        self.offered.insert(name.into(), evidence);
        true
    }
    pub(super) fn active_paths(&self) -> std::collections::HashSet<String> {
        self.runs.iter().filter(|r| !r.finished).map(|r| r.worktree.clone()).collect()
    }
    pub fn pending(&self) -> Vec<String> {
        self.runs
            .iter()
            .filter(|r| !r.delivered)
            .filter_map(|r| r.summary.as_ref().map(|s| format!("{}: {} — {}/{}", r.name, s, repo().display(), r.path)))
            .collect()
    }
    fn unread(&self) -> BTreeMap<String, usize> {
        let mut counts = BTreeMap::new();
        for r in &self.runs {
            if r.commit.is_some() {
                if r.opened || r.proposed {
                    counts.insert(r.name.clone(), 0);
                } else {
                    *counts.entry(r.name.clone()).or_default() += 1;
                }
            }
        }
        counts
    }
    pub fn delivered(&mut self) {
        for r in &mut self.runs {
            if r.summary.is_some() {
                r.delivered = true;
            }
        }
    }
}
fn write(path: &Path, text: &str) -> std::io::Result<()> {
    std::fs::create_dir_all(path.parent().unwrap())?;
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, text)?;
    std::fs::rename(tmp, path)
}
// Rewrite only the matching top-level item. Other items (including invalid
// schemas, comments and formatting) retain their exact bytes. Unsupported
// whole-document flow YAML is refused rather than rewritten wholesale.
fn disable_job_text(text: &str, name: &str) -> Result<String, String> {
    let _: Vec<serde_yaml::Value> = serde_yaml::from_str(text).map_err(|e| e.to_string())?;
    let mut offset = 0;
    let mut starts = Vec::new();
    for line in text.split_inclusive('\n') {
        let trimmed = line.trim_start();
        if trimmed.starts_with("- ") || trimmed.trim_end() == "-" {
            starts.push((offset, line.len() - trimmed.len()));
        }
        offset += line.len();
    }
    let indent = starts.iter().map(|(_, n)| *n).min().ok_or("unsupported schedule layout")?;
    let starts: Vec<_> = starts.into_iter().filter(|(_, n)| *n == indent).map(|(at, _)| at).collect();
    for (i, start) in starts.iter().enumerate() {
        let end = starts.get(i + 1).copied().unwrap_or(text.len());
        let block = &text[*start..end];
        let Ok(mut entries) = serde_yaml::from_str::<Vec<serde_yaml::Value>>(block) else { continue };
        if entries.len() != 1 || entries[0].get("name").and_then(serde_yaml::Value::as_str) != Some(name) {
            continue;
        }
        entries[0]["enabled"] = serde_yaml::Value::Bool(false);
        // Keep trailing comments/blank lines byte-for-byte as part of the surrounding file.
        let content_end = block
            .split_inclusive('\n')
            .scan(0, |at, line| {
                *at += line.len();
                Some((*at, line))
            })
            .filter(|(_, line)| !line.trim().is_empty() && !line.trim_start().starts_with('#'))
            .map(|(at, _)| at)
            .last()
            .unwrap_or(0);
        let encoded = serde_yaml::to_string(&entries).map_err(|e| e.to_string())?;
        let encoded = encoded.lines().map(|line| format!("{}{line}\n", " ".repeat(indent))).collect::<String>();
        return Ok(format!("{}{}{}{}", &text[..*start], encoded, &block[content_end..], &text[end..]));
    }
    Err("schedule item not found or unsupported layout".into())
}
fn read_entries(dir: &Path) -> Result<Vec<serde_yaml::Value>, String> {
    match std::fs::read_to_string(dir.join("schedules.yml")) {
        Ok(s) => serde_yaml::from_str(&s).map_err(|e| e.to_string()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(vec![]),
        Err(e) => Err(e.to_string()),
    }
}
fn read_jobs(dir: &Path) -> Result<Vec<Job>, String> {
    match std::fs::read_to_string(dir.join("schedules.yml")) {
        Ok(s) => {
            let entries: Vec<serde_yaml::Value> = serde_yaml::from_str(&s).map_err(|e| e.to_string())?;
            let jobs = entries.into_iter().filter_map(|v| serde_yaml::from_value::<Job>(v).ok()).filter(Job::validate).collect();
            Ok(jobs)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(vec![]),
        Err(e) => Err(e.to_string()),
    }
}
fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let o = Command::new("git").arg("-C").arg(dir).args(args).output().map_err(|e| e.to_string())?;
    if o.status.success() {
        Ok(String::from_utf8_lossy(&o.stdout).trim().to_string())
    } else {
        Err(String::from_utf8_lossy(&o.stderr).trim().to_string())
    }
}
fn repo() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join("seahelm-research")
}
fn ensure_repo(path: &Path) -> Result<(), String> {
    std::fs::create_dir_all(path).map_err(|e| e.to_string())?;
    if !path.join(".git").exists() && std::fs::read_dir(path).map_err(|e| e.to_string())?.next().is_none() {
        git(path, &["init", "-b", "main"])?;
    }
    let top = git(path, &["rev-parse", "--show-toplevel"])?;
    if Path::new(&top).canonicalize().ok() != path.canonicalize().ok() {
        return Err("research path is not a repository root".into());
    }
    git(path, &["rev-parse", "--show-toplevel"])?;
    if git(path, &["rev-parse", "HEAD"]).is_err() {
        git(
            path,
            &[
                "-c",
                "user.name=Seahelm",
                "-c",
                "user.email=seahelm@localhost",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "core.hooksPath=/dev/null",
                "commit",
                "--allow-empty",
                "-m",
                "Initialize research repository",
            ],
        )?;
    }
    let config_dir = path.parent().unwrap().join(".config/seahelm");
    std::fs::create_dir_all(&config_dir).map_err(|e| e.to_string())?;
    let mut repos = crate::discovery::RepoSet::open(config_dir.join(crate::discovery::FILE_NAME));
    repos.add(&path.to_string_lossy());
    repos.save().map_err(|e| e.to_string())?;
    Ok(())
}
fn committed_report(dir: &Path, path: &str, baseline: &str) -> Option<String> {
    let range = if baseline.is_empty() { "HEAD".to_string() } else { format!("{baseline}..HEAD") };
    let oid = git(dir, &["log", "-1", "--format=%H", &range, "--", path]).ok()?;
    if oid.is_empty() {
        return None;
    }
    git(dir, &["show", &format!("{oid}:{path}")]).ok()?;
    Some(oid)
}
// Lifecycle decisions have no daemon or git dependency.
fn advance_run(r: &mut Run, now: f64, alive: bool, idle: bool, report: impl FnOnce() -> Option<String>) {
    if r.finished {
        return;
    }
    r.commit = report();
    r.finished = !alive || now >= r.started + f64::from(r.minutes) * 60.0 + DEADLINE_GRACE || (r.commit.is_some() && idle);
}
fn expire_summary(r: &mut Run, now: f64, lang: super::lang::Lang) {
    if r.cleaned && r.commit.is_some() && r.summary.is_none() && r.attempts >= SUMMARY_ATTEMPTS && now - r.notified_at >= 600.0 {
        r.summary = Some(lang.pick("No summary available", "暂无摘要").into());
    }
}
fn launch_run(tx: std::sync::mpsc::Sender<super::Msg>, id: u64, build: impl FnOnce() -> Result<Run, String> + Send + 'static) {
    std::thread::spawn(move || {
        let result = build();
        let _ = tx.send(super::Msg::ResearchLaunched { id, result });
    });
}
fn abort_merge(repo: &Path) {
    if git(repo, &["rev-parse", "-q", "--verify", "MERGE_HEAD"]).is_ok() {
        let _ = git(repo, &["merge", "--abort"]);
    }
}
fn validate_worktree(repo: &Path, worktree: &Path) -> Result<(), String> {
    let root = repo.canonicalize().map_err(|e| e.to_string())?;
    let target = worktree.canonicalize().map_err(|e| e.to_string())?;
    let entries = crate::discovery::parse_porcelain(&git(repo, &["worktree", "list", "--porcelain"])?);
    let main = entries.first().and_then(|e| Path::new(&e.path).canonicalize().ok());
    if main.as_ref() != Some(&root) || target == root || !entries.iter().skip(1).any(|e| Path::new(&e.path).canonicalize().ok().as_ref() == Some(&target)) {
        return Err("refusing cleanup: not a linked worktree of the research repository".into());
    }
    Ok(())
}
fn cleanup_run(repo: &Path, r: &Run, kill: impl FnOnce(), remove: impl FnOnce(&str) -> Result<(), String>) -> Result<(), String> {
    validate_worktree(repo, Path::new(&r.worktree))?;
    let result = cleanup_verified(repo, r, kill, remove);
    if result.is_err() {
        abort_merge(repo);
    }
    result
}
fn cleanup_verified(repo: &Path, r: &Run, kill: impl FnOnce(), remove: impl FnOnce(&str) -> Result<(), String>) -> Result<(), String> {
    kill();
    let worktree = Path::new(&r.worktree);
    // Stage only tracked changes and new report files; never force-add ignored data.
    git(worktree, &["add", "-u"])?;
    if worktree.join("reports").is_dir() {
        git(worktree, &["add", "--", "reports/"])?;
    }
    let added = git(worktree, &["diff", "--cached", "--diff-filter=A", "--name-only", "-z"])?;
    for path in added.split('\0').filter(|p| !p.is_empty() && !p.starts_with("reports/")) {
        git(worktree, &["restore", "--staged", "--", path])?;
    }
    let untracked = git(worktree, &["ls-files", "--others", "--exclude-standard", "-z"])?;
    let ignored = git(worktree, &["ls-files", "--others", "--ignored", "--exclude-standard", "-z"])?;
    if !git(worktree, &["diff", "--cached", "--name-only"])?.is_empty() {
        git(
            worktree,
            &[
                "-c",
                "user.name=Seahelm",
                "-c",
                "user.email=seahelm@localhost",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "core.hooksPath=/dev/null",
                "commit",
                "-m",
                "Preserve unfinished research work",
            ],
        )?;
    }
    if !untracked.is_empty() || !ignored.is_empty() {
        return Err("untracked or ignored files remain; keeping the worktree and branch".into());
    }
    if r.commit.is_some() {
        if git(repo, &["branch", "--show-current"])? != "main" {
            return Err("research main checkout is not on main".into());
        }
        let head = git(worktree, &["rev-parse", "HEAD"])?;
        if !git(repo, &["status", "--porcelain"])?.is_empty() {
            abort_merge(repo);
            return Err("research main is dirty; keeping the run branch".into());
        }
        let merged = git(
            repo,
            &[
                "-c",
                "user.name=Seahelm",
                "-c",
                "user.email=seahelm@localhost",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "core.hooksPath=/dev/null",
                "merge",
                "--ff-only",
                &head,
            ],
        );
        if let Err(why) = merged {
            abort_merge(repo);
            return Err(why);
        }
    }
    remove(&r.worktree)
}
impl FirstMate {
    pub(super) fn research_rpc(&mut self, method: &str, p: &Value, now: f64) -> RpcResult {
        let l = self.config.language;
        let name = p["name"].as_str().unwrap_or_default();
        if method == "research.summary" {
            if !policy::is_first_mate(p) {
                return Err(super::refused(l.pick("Only First Mate writes research summaries", "只有 First Mate 可以写入调研摘要")));
            }
            let summary = p["summary"].as_str().unwrap_or_default().split_whitespace().collect::<Vec<_>>().join(" ");
            if summary.is_empty() || summary.chars().count() > 400 {
                return Err(RpcError::invalid_params(l.pick("summary must contain 1–400 characters", "摘要须为 1–400 个字符")));
            }
            let r = self
                .research
                .runs
                .iter_mut()
                .find(|r| r.name == name && r.commit.is_some() && r.summary.is_none())
                .ok_or_else(|| RpcError::invalid_params(l.pick("no committed report awaits a summary", "没有等待摘要的已提交报告")))?;
            r.summary = Some(summary);
            self.research.save(&self.dir);
            return Ok(json!({"stored": true}));
        }
        let mut jobs = read_jobs(&self.dir).map_err(RpcError::invalid_params)?;
        let mut raw = read_entries(&self.dir).map_err(RpcError::invalid_params)?;
        match method {
            "schedule.list" => {
                let invalid: Vec<_> = raw
                    .iter()
                    .enumerate()
                    .filter(|(_, v)| !serde_yaml::from_value::<Job>((*v).clone()).is_ok_and(|j| j.validate()))
                    .map(|(index, v)| json!({"index": index, "name": v.get("name").and_then(serde_yaml::Value::as_str)}))
                    .collect();
                return Ok(json!({"schedules": jobs, "invalid": invalid}));
            }
            "schedule.add" => {
                let j: Job = serde_json::from_value(p.clone()).map_err(|e| RpcError::invalid_params(e.to_string()))?;
                if !j.validate() {
                    return Err(RpcError::invalid_params(l.pick("invalid name, cron, brief or budget", "任务名称、cron、说明或预算无效")));
                }
                if jobs.iter().any(|old| old.name == j.name) {
                    return Err(RpcError::invalid_params(l.pick("schedule already exists; remove it first", "任务已存在，请先移除")));
                }
                raw.push(serde_yaml::to_value(&j).unwrap());
                jobs.push(j.clone());
                self.research.approved.push(j);
            }
            "schedule.remove" => {
                raw.retain(|v| v.get("name").and_then(serde_yaml::Value::as_str) != Some(name));
                jobs.retain(|j| j.name != name);
                self.research.approved.retain(|j| j.name != name);
            }
            "schedule.run_now" => {
                let j = jobs.into_iter().find(|j| j.name == name).ok_or_else(|| RpcError::invalid_params(l.pick("schedule not found", "未找到任务")))?;
                return self
                    .start_research(&j, now)
                    .map(|_| json!({"started": name}))
                    .map_err(|why| super::refused(format!("{}: {why}", l.pick("Research was not started", "调研未启动"))));
            }
            _ => return Err(RpcError::invalid_params(l.pick("unknown schedule method", "未知的调度方法"))),
        }
        write(&self.dir.join("schedules.yml"), &serde_yaml::to_string(&raw).unwrap()).map_err(|e| RpcError::internal(e.to_string()))?;
        self.research.save(&self.dir);
        Ok(json!({"saved": true}))
    }
    fn start_research(&mut self, j: &Job, now: f64) -> Result<(), String> {
        if !self.running || self.config.paused || self.any_quiet_hours(now) {
            return Err("First Mate is off, paused or in quiet hours".into());
        }
        if !j.enabled || !self.research.approved.contains(j) {
            return Err("schedule has no standing approval".into());
        }
        if self.level(Action::StartAgent) == Level::Deny {
            return Err("start_agent is denied".into());
        }
        if self.research_starting || self.research.runs.iter().filter(|r| !r.finished).count() >= MAX_RESEARCH_RUNS {
            return Err("global research concurrency limit reached; firing skipped".into());
        }
        if super::usage_percent().is_some_and(|u| u >= j.budget.pause_above_usage) {
            return Err("schedule usage ceiling reached".into());
        }
        let repo = repo();
        let params = json!({"repo_path": repo.to_string_lossy()});
        if let Some(why) = self.budget_refusal(&params) {
            return Err(why);
        }
        let config = self.config_for(&repo.to_string_lossy())?;
        if config.autonomy(Action::StartAgent, None) == Level::Deny || self.quiet_now(config.settings.quiet_hours, now) {
            return Err("research repository policy refuses this run".into());
        }
        let params = json!({"repo_path": repo.to_string_lossy()});
        self.standing_research = true;
        let gate = self.gate(Action::StartAgent, "worktree.create", &params, now);
        self.standing_research = false;
        if gate != super::Gate::Allow {
            return Err("research start refused by policy".into());
        }
        self.research_starting = true;
        self.research_launch_id += 1;
        let id = self.research_launch_id;
        self.research_launch_at = Some(now);
        let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        self.research_cancel = Some(cancel.clone());
        let j = j.clone();
        let agent = self.config.agent.raw().to_string();
        let core = self.core.clone();
        let tx = self.tx.clone();
        launch_run(tx, id, move || {
            ensure_repo(&repo)?;
            core.publish_event(json!({"type": "worktree.discovered", "worktree_path": repo, "pane_session_key": ""}));
            let path = format!("reports/{}/{}.md", j.name, Local::at(now).day_key());
            let task = format!("Research {}. {}\nWrite the report to {}. Commit it with git, then end.", j.name, j.brief, path);
            let params = json!({"repo_path": repo, "prompt": task, "agent_type": agent});
            let baseline = git(&repo, &["rev-parse", "main"])?;
            if cancel.load(std::sync::atomic::Ordering::SeqCst) {
                return Err("research launch timed out".into());
            }
            let result = core.act("worktree.create", &params).map_err(|e| e.message)?;
            core.note_performed("worktree.create", &params, &result, super::observations::By::FirstMate, Some(&format!("research:{}", j.name)), None, None);
            Ok(Run {
                name: j.name,
                worktree: result["worktree_path"].as_str().unwrap_or_default().into(),
                session: result["pane_session_key"].as_str().unwrap_or_default().into(),
                branch: result["branch"].as_str().unwrap_or_default().into(),
                path,
                started: seahelm_core_types::now(),
                baseline,
                minutes: j.budget.max_minutes,
                ..Default::default()
            })
        });
        self.research.save(&self.dir);
        Ok(())
    }
    pub(super) fn research_tick(&mut self, now: f64) {
        self.expire_research_launch(now);
        let minute = (now / 60.0).floor() as i64;
        if self.research_minute != Some(minute) {
            self.research_minute = Some(minute);
            if self.research.take_minute(now) {
                self.research.save(&self.dir);
                let valid = read_jobs(&self.dir).unwrap_or_default();
                let bad = read_entries(&self.dir).map(|entries| entries.len() != valid.len()).unwrap_or(true);
                let text = std::fs::read_to_string(self.dir.join("schedules.yml")).unwrap_or_default();
                if bad && self.research.bad_schedule_text.as_deref() != Some(&text) {
                    self.core.first_mate_line(self.config.language.pick(
                        "Skipped invalid schedule entries; valid jobs still run. Use schedule remove/add to fix them.",
                        "已跳过无效调度条目，其他任务继续运行。可用 schedule remove/add 修复。",
                    ));
                    self.research.bad_schedule_text = Some(text);
                } else if !bad {
                    self.research.bad_schedule_text = None;
                }
                for j in valid {
                    if Cron::parse(&j.cron).is_some_and(|c| c.matches(&Local::at(now))) {
                        if let Err(why) = self.start_research(&j, now) {
                            self.log(super::engine::Entry::new(now, "research.skipped", format!("{}: {why}", j.name)));
                        }
                    }
                }
            }
        }
        let mut events = vec![];
        for r in &mut self.research.runs {
            if r.cleaned || r.cleanup_stopped {
                continue;
            }
            let alive = seahelmd::client::connect(&r.session).is_ok();
            let worktree = r.worktree.clone();
            let path = r.path.clone();
            let baseline = r.baseline.clone();
            advance_run(r, now, alive, self.core.pane_status(&r.session) == Some(seahelm_core_types::AgentStatus::Idle), || {
                committed_report(Path::new(&worktree), &path, &baseline)
            });
            if !r.finished {
                continue;
            }
            self.started.remove(&r.worktree);
            if r.commit.is_none() && !r.notified_failure {
                let text = Text::new(format!("Research {} ended without a committed report.", r.name), format!("调研 {} 已结束，未提交报告。", r.name));
                self.core.first_mate_line(text.get(self.config.language));
                r.notified_failure = true;
            }
            let result = cleanup_run(
                &repo(),
                r,
                || {
                    let _ = self.core.act("pane.close", &json!({"pane_session_key": r.session}));
                },
                |path| {
                    let params = json!({"worktree_path": path});
                    let result = self.core.act("worktree.delete", &params).map_err(|e| e.message)?;
                    self.core.note_performed(
                        "worktree.delete",
                        &params,
                        &result,
                        super::observations::By::FirstMate,
                        Some(&format!("research:{}", r.name)),
                        None,
                        None,
                    );
                    Ok(())
                },
            );
            if let Err(why) = &result {
                self.core.first_mate_line(&format!(
                    "{}: {why}",
                    self.config.language.pick("Research cleanup stopped; worktree and branch retained", "调研清理已停止，已保留 worktree 和分支")
                ));
                r.cleanup_stopped = true;
            }
            if result.is_ok() {
                r.cleaned = true;
                self.started.remove(&r.worktree);
                if r.commit.is_some() {
                    *self.research.completed.entry(r.name.clone()).or_default() += 1;
                }
            }
        }
        for r in &mut self.research.runs {
            expire_summary(r, now, self.config.language);
        }
        if !self.config.paused
            && !self.any_quiet_hours(now)
            && self.awaiting_since.is_none()
            && self.core.pane_status(policy::SESSION) == Some(seahelm_core_types::AgentStatus::Idle)
        {
            let mut jobs = std::collections::HashSet::new();
            for i in 0..self.research.runs.len() {
                let r = &self.research.runs[i];
                if r.commit.is_none() || !r.cleaned || r.summary.is_some() {
                    continue;
                }
                if !jobs.insert(r.name.clone()) || now - r.notified_at < 600.0 {
                    continue;
                }
                if r.attempts >= SUMMARY_ATTEMPTS {
                    self.research.runs[i].summary = Some(self.config.language.pick("No summary available", "暂无摘要").into());
                    continue;
                }
                let previous = self.research.runs[..i]
                    .iter()
                    .rev()
                    .find(|old| old.name == r.name && old.commit.is_some())
                    .map(|old| format!("git -C {} show {}:{}", repo().display(), old.commit.as_deref().unwrap(), old.path))
                    .unwrap_or_else(|| "none (first report)".into());
                events.push(format!("[seahelm event] research.done\nJob: {}\nReport: {}/{}\nCommit: {}\nPrevious: {}\nCompare the reports. Store a short what-changed summary using seahelm research summary '{}' '<summary>'.", r.name, repo().display(), r.path, r.commit.as_deref().unwrap(), previous, r.name));
                self.research.runs[i].notified_at = now;
                self.research.runs[i].attempts += 1;
            }
            if !events.is_empty() {
                self.tell(&events.join("\n\n"));
            }
        }
        if self.config.paused || self.any_quiet_hours(now) {
            self.research.save(&self.dir);
            return;
        }
        let unread = self.research.unread();
        for (name, n) in unread {
            if !self.research.offer_due(&name, n) {
                continue;
            }
            let text =
                Text::new(format!("Nobody opened the last {n} reports for {name}. Stop this job?"), format!("{name} 连续 {n} 次报告无人查看，要停止吗？"));
            let payload = format!("research.stop:{name}");
            let l = self.config.language;
            self.put_card(
                seahelm_core_registry::cards::CardKind::Proposal,
                &payload,
                text.get(l).into(),
                vec![l.pick("Stop job", "停止任务").into(), l.pick("Not now", "暂不停止").into()],
                budget::Class::Proactive,
                now,
            );
            if let Some(r) = self.research.runs.iter_mut().rev().find(|r| r.name == name) {
                r.proposed = true;
            }
        }
        let mut retained = BTreeMap::<String, usize>::new();
        self.research.runs.reverse();
        self.research.runs.retain(|r| {
            let n = retained.entry(r.name.clone()).or_default();
            *n += 1;
            !r.cleaned || (r.commit.is_some() && !r.delivered) || *n <= 3
        });
        self.research.runs.reverse();
        self.research.save(&self.dir);
    }
    pub(super) fn expire_research_launch(&mut self, now: f64) {
        if self.research_launch_at.is_some_and(|at| now - at >= LAUNCH_TIMEOUT) {
            self.research_starting = false;
            self.research_launch_at = None;
            self.research_launch_id += 1;
            if let Some(cancel) = self.research_cancel.take() {
                cancel.store(true, std::sync::atomic::Ordering::SeqCst);
            }
            self.core.first_mate_line(self.config.language.pick("Research launch timed out; the start slot was released.", "调研启动超时，已释放启动名额。"));
        }
    }
    pub(super) fn research_launched(&mut self, id: u64, result: Result<Run, String>, now: f64) {
        if id != self.research_launch_id {
            if let Ok(mut r) = result {
                r.started = now - f64::from(r.minutes) * 60.0 - DEADLINE_GRACE;
                self.research.runs.push(r);
                self.research.save(&self.dir);
            }
            return;
        }
        self.research_starting = false;
        self.research_launch_at = None;
        self.research_cancel = None;
        match result {
            Ok(r) => {
                let mut entry = super::engine::Entry::new(now, "research.started", format!("Started under schedule {} created by the user", r.name));
                entry.level = Some("schedule".into());
                entry.detail = Some(r.name.clone());
                self.log(entry);
                self.started.insert(r.worktree.clone());
                self.research.runs.push(r);
                self.research.save(&self.dir);
            }
            Err(why) => {
                self.core.first_mate_line(&format!("{}: {why}", self.config.language.pick("Research launch failed", "调研启动失败")));
                self.log(super::engine::Entry::new(now, "research.skipped", why));
            }
        }
    }
    pub(super) fn research_answer(&mut self, payload: &str, option: Option<&str>) -> bool {
        let Some(name) = payload.strip_prefix("research.stop:") else { return false };
        if matches!(option, Some("choice:0" | "Stop job" | "停止任务")) {
            for j in &mut self.research.approved {
                if j.name == name {
                    j.enabled = false;
                }
            }
            self.research.save(&self.dir);
            let path = self.dir.join("schedules.yml");
            let result = std::fs::read_to_string(&path)
                .map_err(|e| e.to_string())
                .and_then(|text| disable_job_text(&text, name))
                .and_then(|text| write(&path, &text).map_err(|e| e.to_string()));
            if let Err(why) = result {
                self.core.first_mate_line(&format!(
                    "{}: {why}",
                    self.config.language.pick("Could not update the schedule file; standing approval was revoked", "无法更新调度文件，持续授权已撤销")
                ));
            }
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_paths_and_invalid_budgets() {
        let mut j = Job {
            name: "../escape".into(),
            cron: "* * * * *".into(),
            brief: "research".into(),
            enabled: true,
            budget: Budget { max_minutes: 30, pause_above_usage: 80.0 },
        };
        assert!(!j.validate());
        j.name = "rust-news".into();
        assert!(j.validate());
        j.budget.pause_above_usage = f64::NAN;
        assert!(!j.validate());
    }
    #[test]
    fn persists_only_summaries_in_pending_brief() {
        let dir = tempfile::tempdir().unwrap();
        let mut s = State::default();
        s.runs.push(Run {
            name: "news".into(),
            worktree: "/research/run".into(),
            path: "reports/news/2026-11-05.md".into(),
            summary: Some("New release".into()),
            ..Default::default()
        });
        s.save(dir.path());
        let mut s = State::load(dir.path());
        assert!(s.pending()[0].contains("New release — "));
        s.delivered();
        assert!(s.pending().is_empty());
    }
    fn fm(dir: &Path) -> FirstMate {
        let core = crate::core::Core::for_test(dir);
        let (tx, _) = std::sync::mpsc::channel();
        FirstMate::new(core, tx, dir.join("first-mate"), dir.join("habits"))
    }
    fn job() -> Job {
        Job { name: "news".into(), cron: "* * * * *".into(), brief: "news".into(), enabled: true, budget: Budget { max_minutes: 1, pause_above_usage: 80.0 } }
    }
    #[test]
    fn only_a_user_created_exact_job_has_standing_approval() {
        let tmp = tempfile::tempdir().unwrap();
        let mut f = fm(tmp.path());
        let j = job();
        f.research_rpc("schedule.add", &json!(j), 100.0).unwrap();
        assert_eq!(read_jobs(&f.dir).unwrap(), vec![j.clone()]);
        assert_eq!(State::load(&f.dir).approved, vec![j.clone()]);
        f.running = true;
        let mut edited = j.clone();
        edited.brief = "different authority".into();
        assert_eq!(f.start_research(&edited, 100.0).unwrap_err(), "schedule has no standing approval");
        f.config.paused = true;
        assert!(f.start_research(&j, 100.0).unwrap_err().contains("paused"));
        f.research_rpc("schedule.remove", &json!({"name": "news"}), 100.0).unwrap();
        assert!(State::load(&f.dir).approved.is_empty());
    }
    #[test]
    fn standing_approval_is_scoped_to_start_agent_and_deny_survives() {
        let tmp = tempfile::tempdir().unwrap();
        let mut f = fm(tmp.path());
        f.running = true;
        f.standing_research = true;
        // Standing jobs do not consume or depend on the user's per-turn route mandate.
        f.user_spoke = true;
        f.route_used = true;
        assert_eq!(f.gate(Action::StartAgent, "worktree.create", &json!({}), 100.0), super::super::Gate::Allow);
        f.config.defaults.insert(Action::StartAgent, Level::Deny);
        assert!(matches!(f.gate(Action::StartAgent, "worktree.create", &json!({}), 100.0), super::super::Gate::Deny(_)));
        assert!(matches!(f.gate(Action::DeleteWorktree, "worktree.delete", &json!({}), 100.0), super::super::Gate::Queued(_)));
    }
    #[test]
    fn visits_and_followups_reset_only_their_job_streak() {
        let mut s = State::default();
        for n in 0..3 {
            s.runs.push(Run {
                name: "news".into(),
                worktree: format!("/scratch/{n}"),
                path: format!("reports/news/{n}.md"),
                commit: Some(format!("{n}")),
                ..Default::default()
            });
        }
        assert_eq!(s.unread()["news"], 3);
        s.seen(&["/scratch/1".into()]);
        assert_eq!(s.unread()["news"], 1);
        s.followup("Explain reports/news/2.md");
        assert_eq!(s.unread()["news"], 0);
    }
    #[test]
    fn initializes_and_registers_a_scratch_repo_without_overwriting_config() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("research");
        let cfg = tmp.path().join(".config/seahelm/config.json");
        write(&cfg, r#"{"theme":"dark","workspace_paths":["/existing"]}"#).unwrap();
        ensure_repo(&path).unwrap();
        ensure_repo(&path).unwrap();
        assert!(!git(&path, &["rev-parse", "HEAD"]).unwrap().is_empty());
        let v: Value = serde_json::from_slice(&std::fs::read(cfg).unwrap()).unwrap();
        assert_eq!(v["theme"], "dark");
        assert_eq!(v["workspace_paths"].as_array().unwrap().len(), 1);
    }
    #[test]
    fn matching_minutes_are_consumed_once_and_never_replayed() {
        let mut s = State::default();
        assert!(s.take_minute(60.0));
        assert!(!s.take_minute(119.0));
        assert!(s.take_minute(600.0));
        assert_eq!(s.last_minute, Some(10));
        let dir = tempfile::tempdir().unwrap();
        s.save(dir.path());
        assert!(!State::load(dir.path()).take_minute(601.0));
    }
    #[test]
    fn stop_revokes_the_original_standing_approval() {
        let dir = tempfile::tempdir().unwrap();
        let mut f = fm(dir.path());
        let j = job();
        f.research_rpc("schedule.add", &json!(j), 100.0).unwrap();
        assert!(f.research_answer("research.stop:news", Some("Stop job")));
        assert!(!State::load(&f.dir).approved.contains(&j));
        assert!(!read_jobs(&f.dir).unwrap()[0].enabled);
    }
    #[test]
    fn summary_is_first_mates_and_is_written_against_the_oldest_pending_report() {
        let dir = tempfile::tempdir().unwrap();
        let mut f = fm(dir.path());
        for day in 1..=2 {
            f.research.runs.push(Run { name: "news".into(), path: format!("reports/news/{day}.md"), commit: Some(format!("{day}")), ..Default::default() });
        }
        let p = json!({"name": "news", "summary": "A new release"});
        assert!(f.research_rpc("research.summary", &p, 100.0).is_err());
        let mut p = p;
        p["_meta"] = json!({"caller": policy::SESSION});
        f.research_rpc("research.summary", &p, 100.0).unwrap();
        assert_eq!(f.research.runs[0].summary.as_deref(), Some("A new release"));
        assert!(f.research.runs[1].summary.is_none());
        p["summary"] = json!("x".repeat(401));
        assert!(f.research_rpc("research.summary", &p, 100.0).is_err());
    }
    #[test]
    fn vanished_sessions_and_deadlines_finish_without_a_successful_interrupt() {
        let mut gone = Run { started: 100.0, minutes: 1, ..Default::default() };
        advance_run(&mut gone, 101.0, false, false, || None);
        assert!(gone.finished);
        advance_run(&mut gone, 200.0, true, true, || panic!("finished runs must never poll git"));
        let mut due = Run { started: 100.0, minutes: 1, ..Default::default() };
        advance_run(&mut due, 189.0, true, false, || None);
        assert!(!due.finished);
        advance_run(&mut due, 190.0, true, false, || None);
        assert!(due.finished);
    }
    #[test]
    fn research_only_briefs_render_in_both_languages() {
        use super::super::{
            brief::{compose, Inputs},
            lang::Lang,
        };
        for (lang, heading) in [(Lang::En, "Research: "), (Lang::Zh, "调研：")] {
            let text = compose(&Inputs { lang, research: vec!["news: Changes — /research/reports/news/date.md".into()], ..Default::default() }).unwrap();
            assert!(text.contains(heading));
            assert!(text.contains("/research/reports/news/date.md"));
        }
    }
    #[test]
    fn an_inherited_or_uncommitted_report_does_not_finish_a_new_run() {
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path().join("research");
        ensure_repo(&repo).unwrap();
        std::fs::write(repo.join("report.md"), "old").unwrap();
        git(&repo, &["add", "report.md"]).unwrap();
        let commit = || {
            git(
                &repo,
                &[
                    "-c",
                    "user.name=test",
                    "-c",
                    "user.email=test@localhost",
                    "-c",
                    "commit.gpgsign=false",
                    "-c",
                    "core.hooksPath=/dev/null",
                    "commit",
                    "-m",
                    "Report",
                ],
            )
        };
        commit().unwrap();
        let baseline = git(&repo, &["rev-parse", "HEAD"]).unwrap();
        assert!(committed_report(&repo, "report.md", &baseline).is_none());
        std::fs::write(repo.join("report.md"), "new").unwrap();
        assert!(committed_report(&repo, "report.md", &baseline).is_none());
        git(&repo, &["add", "report.md"]).unwrap();
        commit().unwrap();
        assert!(committed_report(&repo, "report.md", &baseline).is_some());
    }
    fn commit(dir: &Path) {
        git(dir, &["add", "-A"]).unwrap();
        git(
            dir,
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@localhost",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "core.hooksPath=/dev/null",
                "commit",
                "-m",
                "Report",
            ],
        )
        .unwrap();
    }
    #[test]
    fn completed_report_merges_to_main_before_injected_cleanup() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("research");
        ensure_repo(&root).unwrap();
        let wt = tmp.path().join("run");
        git(&root, &["worktree", "add", "-b", "run", wt.to_str().unwrap()]).unwrap();
        std::fs::write(wt.join("report.md"), "committed report").unwrap();
        commit(&wt);
        let oid = git(&wt, &["rev-parse", "HEAD"]).unwrap();
        let r = Run { worktree: wt.to_string_lossy().into(), commit: Some(oid.clone()), ..Default::default() };
        let killed = std::cell::Cell::new(false);
        let removed = std::cell::Cell::new(false);
        cleanup_run(
            &root,
            &r,
            || killed.set(true),
            |path| {
                assert!(killed.get());
                assert_eq!(path, wt.to_str().unwrap());
                assert_eq!(std::fs::read_to_string(root.join("report.md")).unwrap(), "committed report");
                removed.set(true);
                Ok(())
            },
        )
        .unwrap();
        assert!(removed.get());
        assert_eq!(git(&root, &["merge-base", "--is-ancestor", &oid, "main"]).unwrap(), "");
    }
    #[test]
    fn failed_run_preserves_partial_work_on_branch_without_merging() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("research");
        ensure_repo(&root).unwrap();
        let wt = tmp.path().join("run");
        git(&root, &["worktree", "add", "-b", "partial", wt.to_str().unwrap()]).unwrap();
        std::fs::write(wt.join("partial.md"), "unfinished").unwrap();
        std::fs::write(wt.join(".gitignore"), ".env\n").unwrap();
        std::fs::write(wt.join(".env"), "TEST_ONLY=true").unwrap();
        let r = Run { worktree: wt.to_string_lossy().into(), ..Default::default() };
        assert!(cleanup_run(&root, &r, || {}, |_| panic!("untracked data must not be removed")).is_err());
        assert_eq!(std::fs::read_to_string(wt.join("partial.md")).unwrap(), "unfinished");
        assert!(!root.join("partial.md").exists());
        assert!(git(&root, &["show", "partial:.env"]).is_err());
    }
    #[test]
    fn invalid_entry_does_not_disable_valid_jobs_or_block_cli_repair() {
        let dir = tempfile::tempdir().unwrap();
        let mut f = fm(dir.path());
        let valid = serde_yaml::to_value(job()).unwrap();
        let invalid: serde_yaml::Value = serde_yaml::from_str("{name: broken, cron: invalid}").unwrap();
        write(&f.dir.join("schedules.yml"), &serde_yaml::to_string(&vec![valid, invalid]).unwrap()).unwrap();
        assert_eq!(read_jobs(&f.dir).unwrap().len(), 1);
        f.research_rpc("schedule.remove", &json!({"name":"broken"}), 100.0).unwrap();
        assert_eq!(read_entries(&f.dir).unwrap().len(), 1);
        let mut j = job();
        j.name = "other".into();
        f.research_rpc("schedule.add", &json!(j), 100.0).unwrap();
        assert_eq!(read_jobs(&f.dir).unwrap().len(), 2);
    }
    #[test]
    fn global_concurrency_reserves_starting_and_active_runs_only() {
        let dir = tempfile::tempdir().unwrap();
        let mut f = fm(dir.path());
        f.running = true;
        f.research.approved.push(job());
        f.research_starting = true;
        assert!(f.start_research(&job(), 100.0).unwrap_err().contains("concurrency"));
        f.research_starting = false;
        f.research.runs.push(Run::default());
        assert!(f.start_research(&job(), 100.0).unwrap_err().contains("concurrency"));
        f.research.runs[0].finished = true;
        assert_eq!(f.research.runs.iter().filter(|r| !r.finished).count(), 0);
    }
    #[test]
    fn state_is_not_rewritten_without_changes() {
        let dir = tempfile::tempdir().unwrap();
        let s = State::default();
        s.save(dir.path());
        let path = dir.path().join("research.json");
        let before = std::fs::metadata(&path).unwrap().modified().unwrap();
        s.save(dir.path());
        assert_eq!(before, std::fs::metadata(path).unwrap().modified().unwrap());
    }
    #[test]
    fn summary_attempts_are_capped_and_fallback_does_not_need_an_idle_model() {
        let mut r = Run { cleaned: true, commit: Some("oid".into()), attempts: 2, notified_at: 100.0, ..Default::default() };
        expire_summary(&mut r, 700.0, super::super::lang::Lang::Zh);
        assert!(r.summary.is_none());
        r.attempts = 3;
        expire_summary(&mut r, 699.0, super::super::lang::Lang::Zh);
        assert!(r.summary.is_none());
        expire_summary(&mut r, 700.0, super::super::lang::Lang::Zh);
        assert_eq!(r.summary.as_deref(), Some("暂无摘要"));
    }
    #[test]
    fn stop_proposals_wait_for_new_completion_evidence() {
        let mut s = State::default();
        s.completed.insert("job".into(), 3);
        assert!(s.offer_due("job", 3));
        assert!(!s.offer_due("job", 3));
        assert!(!s.offer_due("job", 4));
        s.completed.insert("job".into(), 4);
        assert!(s.offer_due("job", 4));
        assert!(!s.offer_due("job", 4));
    }
    #[test]
    fn scheduled_start_is_a_brief_entry_and_does_not_emit_an_ordinary_auto_action() {
        let tmp = tempfile::tempdir().unwrap();
        let mut f = fm(tmp.path());
        f.research_launched(0, Ok(Run { name: "news".into(), worktree: "/scratch/report".into(), ..Default::default() }), 100.0);
        let entries = f.audit.recent(10);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].kind, "research.started");
        assert_eq!(entries[0].level.as_deref(), Some("schedule"));
        assert!(entries[0].text.contains("schedule news created by the user"));
        let brief = super::super::brief::compose(&super::super::brief::Inputs { entries, ..Default::default() }).unwrap();
        assert!(brief.contains("your schedule news"));
        assert!(f.started.contains("/scratch/report"));
    }
    #[test]
    fn launch_returns_before_repository_or_agent_work_finishes() {
        let (tx, events) = std::sync::mpsc::channel();
        let (allow, blocked) = std::sync::mpsc::channel();
        let (returned, ready) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            launch_run(tx, 0, move || {
                blocked.recv().unwrap();
                Ok(Run::default())
            });
            returned.send(()).unwrap();
        });
        let result = ready.recv_timeout(std::time::Duration::from_secs(2));
        allow.send(()).unwrap();
        assert!(result.is_ok(), "reply path waited for repository/agent work");
        assert!(matches!(events.recv_timeout(std::time::Duration::from_secs(2)).unwrap(), super::super::Msg::ResearchLaunched { result: Ok(_), .. }));
    }
    #[test]
    fn cleanup_rejects_main_and_foreign_worktrees_before_killing_or_writing() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("research");
        ensure_repo(&root).unwrap();
        let other = tmp.path().join("other");
        ensure_repo(&other).unwrap();
        let wt = tmp.path().join("foreign");
        git(&other, &["worktree", "add", "-b", "foreign", wt.to_str().unwrap()]).unwrap();
        for path in [&root, &wt] {
            let r = Run { worktree: path.to_string_lossy().into(), ..Default::default() };
            assert!(cleanup_run(&root, &r, || panic!("must validate before kill"), |_| panic!("must not delete")).is_err());
        }
    }
    #[test]
    fn divergent_report_is_not_merged_and_no_merge_is_left_in_progress() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("research");
        ensure_repo(&root).unwrap();
        std::fs::write(root.join("report.md"), "base").unwrap();
        commit(&root);
        let wt = tmp.path().join("run");
        git(&root, &["worktree", "add", "-b", "run", wt.to_str().unwrap()]).unwrap();
        std::fs::write(root.join("report.md"), "main").unwrap();
        commit(&root);
        std::fs::write(wt.join("report.md"), "run").unwrap();
        commit(&wt);
        let oid = git(&wt, &["rev-parse", "HEAD"]).unwrap();
        let r = Run { worktree: wt.to_string_lossy().into(), commit: Some(oid), ..Default::default() };
        assert!(cleanup_run(&root, &r, || {}, |_| panic!("keep divergent worktree")).is_err());
        assert!(git(&root, &["rev-parse", "--verify", "MERGE_HEAD"]).is_err());
        assert_eq!(std::fs::read_to_string(root.join("report.md")).unwrap(), "main");
        // Simulate an interrupted earlier merge: cleanup must abort it on failure.
        assert!(git(&root, &["-c", "user.name=test", "-c", "user.email=test@localhost", "merge", "run"]).is_err());
        assert!(git(&root, &["rev-parse", "--verify", "MERGE_HEAD"]).is_ok());
        assert!(cleanup_run(&root, &r, || {}, |_| panic!("keep branch")).is_err());
        assert!(git(&root, &["rev-parse", "--verify", "MERGE_HEAD"]).is_err());
    }
    #[test]
    fn leftovers_stage_reports_and_tracked_changes_but_leave_other_data() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("research");
        ensure_repo(&root).unwrap();
        std::fs::write(root.join("tracked.md"), "old").unwrap();
        commit(&root);
        let wt = tmp.path().join("run");
        git(&root, &["worktree", "add", "-b", "leftovers", wt.to_str().unwrap()]).unwrap();
        std::fs::create_dir(wt.join("reports")).unwrap();
        std::fs::write(wt.join("reports/partial.md"), "partial").unwrap();
        std::fs::write(wt.join("tracked.md"), "changed").unwrap();
        std::fs::write(wt.join("notes.txt"), "keep").unwrap();
        git(&wt, &["add", "notes.txt"]).unwrap();
        let r = Run { worktree: wt.to_string_lossy().into(), ..Default::default() };
        assert!(cleanup_run(&root, &r, || {}, |_| panic!("untracked notes prevent deletion")).is_err());
        assert_eq!(git(&root, &["show", "leftovers:reports/partial.md"]).unwrap(), "partial");
        assert_eq!(git(&root, &["show", "leftovers:tracked.md"]).unwrap(), "changed");
        assert!(git(&root, &["show", "leftovers:notes.txt"]).is_err());
        assert!(wt.join("notes.txt").exists());
    }
    #[test]
    fn committed_report_waits_for_idle_or_deadline() {
        let mut r = Run { started: 100.0, minutes: 1, ..Default::default() };
        advance_run(&mut r, 110.0, true, false, || Some("commit".into()));
        assert!(!r.finished);
        advance_run(&mut r, 111.0, true, true, || Some("commit".into()));
        assert!(r.finished);
        let mut busy = Run { started: 100.0, minutes: 1, ..Default::default() };
        advance_run(&mut busy, 190.0, true, false, || Some("commit".into()));
        assert!(busy.finished);
    }
    #[test]
    fn launch_timeout_releases_slot_and_ignores_stale_failures() {
        let tmp = tempfile::tempdir().unwrap();
        let mut f = fm(tmp.path());
        f.core.ensure_first_mate_pane(&f.dir.to_string_lossy());
        f.research_starting = true;
        f.research_launch_at = Some(100.0);
        f.research_launch_id = 1;
        let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        f.research_cancel = Some(cancel.clone());
        f.expire_research_launch(219.0);
        assert!(f.research_starting);
        f.expire_research_launch(220.0);
        assert!(!f.research_starting);
        assert!(cancel.load(std::sync::atomic::Ordering::SeqCst));
        f.research_starting = true;
        f.research_launch_at = Some(221.0);
        f.research_launched(1, Err("old failure".into()), 222.0);
        assert!(f.research_starting);
        f.research_launched(f.research_launch_id, Err("new failure".into()), 223.0);
        assert!(!f.research_starting);
        use crate::rpc::Dispatch;
        let crate::rpc::Reply::Value(Ok(rows)) = f.core.clone().call("message.snapshot", json!({"pane_id": policy::SESSION})) else {
            panic!("snapshot");
        };
        let notes = rows["messages"].as_array().unwrap();
        assert_eq!(notes.len(), 2, "one timeout note and one new failure note; no stale failure note");
        assert!(notes.iter().all(|r| r["kind"] == "note"));
    }
    #[test]
    fn stopping_job_preserves_invalid_items_comments_and_surrounding_bytes() {
        let tmp = tempfile::tempdir().unwrap();
        let mut f = fm(tmp.path());
        f.research_rpc("schedule.add", &json!(job()), 100.0).unwrap();
        let path = f.dir.join("schedules.yml");
        let prefix = "# keep this header\n- {name: broken, cron: invalid, extra: untouched} # invalid schema\n";
        let suffix = "# keep this comment\n- {name: other, weird: [1, 2]} # also invalid\n";
        let original = format!("{prefix}{}{suffix}", std::fs::read_to_string(&path).unwrap());
        std::fs::write(&path, &original).unwrap();
        f.research_answer("research.stop:news", Some("Stop job"));
        let edited = std::fs::read_to_string(&path).unwrap();
        assert!(edited.starts_with(prefix));
        assert!(edited.ends_with(suffix));
        assert!(!read_jobs(&f.dir).unwrap()[0].enabled);
        assert_eq!(read_entries(&f.dir).unwrap().len(), 3);
    }
    #[test]
    fn stop_cards_follow_rebased_canonical_option_routing_in_both_languages() {
        for lang in [super::super::lang::Lang::En, super::super::lang::Lang::Zh] {
            let tmp = tempfile::tempdir().unwrap();
            let mut f = fm(tmp.path());
            f.config.language = lang;
            f.research_rpc("schedule.add", &json!(job()), 100.0).unwrap();
            let stop = lang.pick("Stop job", "停止任务");
            f.put_card(
                seahelm_core_registry::cards::CardKind::Proposal,
                "research.stop:news",
                "Stop?".into(),
                vec![stop.into(), "Not now".into()],
                budget::Class::Answering,
                100.0,
            );
            f.answered("research.stop:news", Some(stop), None, 101.0);
            assert!(!read_jobs(&f.dir).unwrap()[0].enabled);
        }
    }
}
