//! The morning brief's "yesterday's work": what the user (and the agents
//! working as them) got done on the last working day — commits and lines,
//! pull requests merged and opened, issues closed — set against the working
//! day before it and the same day a week earlier, with the week so far, a
//! seven-day sparkline and the odd milestone, so the brief reads as
//! progress rather than a log.
//!
//! Only the user's identity counts: commits whose author is the repo's
//! `user.email`, pull requests and issues GitHub attributes to `@me`.
//! Agents commit as the user, so their work is in it. A squash merge made on
//! GitHub (committer `noreply@github.com`) is left out: its lines were
//! already counted on the branch.
//!
//! The report is about the last weekday before today (Monday's brief speaks
//! of Friday, with the weekend as an extra line when anything happened), and
//! compares a day with the weekday before it (Monday with Friday). Past days
//! do not change, so each is measured once and kept in
//! `first-mate/daily-stats.json`; the first brief backfills what it compares
//! against from git and GitHub.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::clock::Local;
use super::lang::{plural_en, Lang};

const FILE: &str = "daily-stats.json";
/// Days kept in the file: enough for records and streaks.
const KEEP_DAYS: usize = 120;

/// One local day's work.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Day {
    pub commits: u32,
    pub added: u64,
    pub removed: u64,
    pub files: u32,
    /// None when GitHub could not be asked (no `gh`, not signed in).
    pub prs_merged: Option<u32>,
    pub prs_opened: Option<u32>,
    pub issues_closed: Option<u32>,
    /// Per repo (its directory name), most lines first.
    pub repos: Vec<RepoDay>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct RepoDay {
    pub name: String,
    pub commits: u32,
    pub added: u64,
    pub removed: u64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Store {
    /// By day key ("2026-11-14").
    pub days: BTreeMap<String, Day>,
    /// The last day a brief has spoken of, weekend included.
    pub reported_through: Option<String>,
}

impl Store {
    pub fn load(dir: &Path) -> Store {
        std::fs::read_to_string(dir.join(FILE)).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
    }

    pub fn save(&mut self, dir: &Path) {
        while self.days.len() > KEEP_DAYS {
            let Some(first) = self.days.keys().next().cloned() else { break };
            self.days.remove(&first);
        }
        if let Ok(text) = serde_json::to_string_pretty(self) {
            let tmp = dir.join(format!("{FILE}.tmp"));
            if std::fs::write(&tmp, text).is_ok() {
                let _ = std::fs::rename(&tmp, dir.join(FILE));
            }
        }
    }
}

// MARK: calendar

/// A local day: its key, start and end (Unix seconds), weekday (0 = Sunday).
#[derive(Clone, Debug, PartialEq)]
pub struct DayRef {
    pub key: String,
    pub start: f64,
    pub end: f64,
    pub weekday: u32,
    pub month: u32,
    pub day: u32,
}

impl DayRef {
    /// The local day containing `at`.
    pub fn containing(at: f64, offset: i64) -> DayRef {
        let start = crate::usage::day_start(at, offset);
        let l = Local::with_offset(start + 1.0, offset);
        DayRef { key: l.day_key(), start, end: start + 86_400.0, weekday: l.weekday, month: l.month, day: l.day }
    }

    pub fn before(&self, offset: i64) -> DayRef {
        DayRef::containing(self.start - 43_200.0, offset)
    }

    pub fn is_weekday(&self) -> bool {
        (1..=5).contains(&self.weekday)
    }

    /// The weekday before this day (Monday's is Friday).
    pub fn previous_weekday(&self, offset: i64) -> DayRef {
        let mut d = self.before(offset);
        while !d.is_weekday() {
            d = d.before(offset);
        }
        d
    }

    /// Seven days earlier.
    pub fn week_before(&self, offset: i64) -> DayRef {
        DayRef::containing(self.start - 7.0 * 86_400.0 + 43_200.0, offset)
    }
}

/// What a brief at `now` reports: the last weekday before today, and the
/// days after it up to yesterday (a weekend).
pub fn report_days(now: f64, offset: i64) -> (DayRef, Vec<DayRef>) {
    let today = DayRef::containing(now, offset);
    let day = today.previous_weekday(offset);
    let mut extra = Vec::new();
    let mut d = today.before(offset);
    while d.key != day.key {
        extra.push(d.clone());
        d = d.before(offset);
    }
    extra.reverse();
    (day, extra)
}

/// Every day the report needs: the day, its comparisons, the weekend after
/// it, this week and the same span last week, the sparkline's weekdays.
pub fn days_needed(day: &DayRef, extra: &[DayRef], offset: i64) -> Vec<DayRef> {
    let mut out: Vec<DayRef> = vec![day.clone(), day.previous_weekday(offset), day.week_before(offset)];
    out.extend(extra.iter().cloned());
    for d in week_so_far(day, offset) {
        out.push(d.week_before(offset));
        out.push(d);
    }
    out.extend(last_weekdays(day, 7, offset));
    let mut seen = HashSet::new();
    out.retain(|d| seen.insert(d.key.clone()));
    out.sort_by(|a, b| a.key.cmp(&b.key));
    out
}

/// Monday of `day`'s week through `day`.
fn week_so_far(day: &DayRef, offset: i64) -> Vec<DayRef> {
    let mut out = vec![day.clone()];
    let mut d = day.clone();
    while d.weekday != 1 {
        d = d.before(offset);
        out.push(d.clone());
    }
    out.reverse();
    out
}

/// The `n` weekdays ending with `day`, oldest first.
fn last_weekdays(day: &DayRef, n: usize, offset: i64) -> Vec<DayRef> {
    let mut out = vec![day.clone()];
    while out.len() < n {
        let next = out.last().unwrap().previous_weekday(offset);
        out.push(next);
    }
    out.reverse();
    out
}

// MARK: measuring

/// One commit as `git log` printed it.
#[derive(Clone, Debug, PartialEq)]
pub struct Commit {
    pub hash: String,
    pub at: f64,
    pub committer: String,
    pub added: u64,
    pub removed: u64,
    pub files: u32,
}

/// `git log --format=@%H %ct %ce --numstat`.
pub fn parse_log(text: &str) -> Vec<Commit> {
    let mut out: Vec<Commit> = Vec::new();
    for line in text.lines() {
        if let Some(head) = line.strip_prefix('@') {
            let mut parts = head.split_whitespace();
            let (Some(hash), Some(at)) = (parts.next(), parts.next().and_then(|t| t.parse::<f64>().ok())) else { continue };
            let committer = parts.next().unwrap_or_default().to_string();
            out.push(Commit { hash: hash.to_string(), at, committer, added: 0, removed: 0, files: 0 });
            continue;
        }
        let Some(c) = out.last_mut() else { continue };
        let mut cols = line.split('\t');
        let (Some(a), Some(r), Some(_)) = (cols.next(), cols.next(), cols.next()) else { continue };
        // Binary files show `-`: a file changed, no lines.
        c.added += a.parse::<u64>().unwrap_or(0);
        c.removed += r.parse::<u64>().unwrap_or(0);
        c.files += 1;
    }
    out
}

/// A squash or merge made on GitHub's site: its lines were the branch's.
fn made_on_github(c: &Commit) -> bool {
    c.committer.eq_ignore_ascii_case("noreply@github.com")
}

fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git").arg("-C").arg(dir).args(args).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The user's commits in `repos` between `from` and `to`, each once.
pub fn commits(repos: &[String], from: f64, to: f64) -> Vec<(String, Commit)> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for repo in repos {
        let dir = Path::new(repo);
        let Some(email) = git(dir, &["config", "user.email"]).map(|e| e.trim().to_string()).filter(|e| !e.is_empty()) else { continue };
        let since = format!("--since=@{}", from.floor() as i64);
        let until = format!("--until=@{}", to.ceil() as i64);
        let author = format!("--author=<{email}>");
        let Some(text) = git(dir, &["log", "--all", "--no-merges", &since, &until, &author, "--format=@%H %ct %ce", "--numstat"]) else { continue };
        let name = dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| repo.clone());
        for c in parse_log(&text) {
            if made_on_github(&c) || !seen.insert(c.hash.clone()) {
                continue;
            }
            out.push((name.clone(), c));
        }
    }
    out
}

/// Bucket commits into days.
pub fn tally(days: &[DayRef], commits: &[(String, Commit)]) -> HashMap<String, Day> {
    let mut out: HashMap<String, Day> = days.iter().map(|d| (d.key.clone(), Day::default())).collect();
    for (repo, c) in commits {
        let Some(d) = days.iter().find(|d| c.at >= d.start && c.at < d.end) else { continue };
        let day = out.get_mut(&d.key).unwrap();
        day.commits += 1;
        day.added += c.added;
        day.removed += c.removed;
        day.files += c.files;
        match day.repos.iter_mut().find(|r| r.name == *repo) {
            Some(r) => {
                r.commits += 1;
                r.added += c.added;
                r.removed += c.removed;
            }
            None => day.repos.push(RepoDay { name: repo.clone(), commits: 1, added: c.added, removed: c.removed }),
        }
    }
    for day in out.values_mut() {
        day.repos.sort_by(|a, b| (b.added + b.removed).cmp(&(a.added + a.removed)));
    }
    out
}

/// GitHub's search, through `gh`: every item's `field` timestamp (Unix),
/// up to 300 items. None when `gh` cannot answer.
fn gh_search(query: &str, field: impl Fn(&Value) -> Option<String>) -> Option<Vec<(String, f64)>> {
    let mut out = Vec::new();
    for page in 1..=3 {
        let res = Command::new("gh")
            .args(["api", "-X", "GET", "search/issues", "-f", &format!("q={query}"), "-f", "per_page=100", "-f", &format!("page={page}")])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()?;
        if !res.status.success() {
            return None;
        }
        let v: Value = serde_json::from_slice(&res.stdout).ok()?;
        let items = v.get("items").and_then(Value::as_array).cloned().unwrap_or_default();
        for item in &items {
            let url = item.get("html_url").and_then(Value::as_str).unwrap_or_default().to_string();
            if let Some(at) = field(item).as_deref().and_then(crate::usage::parse_iso8601) {
                out.push((url, at));
            }
        }
        if items.len() < 100 {
            break;
        }
    }
    Some(out)
}

/// Count timestamps per day; `None` stays `None` for every day.
fn per_day(days: &[DayRef], stamps: Option<&[(String, f64)]>) -> HashMap<String, Option<u32>> {
    days.iter()
        .map(|d| (d.key.clone(), stamps.map(|s| s.iter().filter(|(_, at)| *at >= d.start && *at < d.end).count() as u32)))
        .collect()
}

/// Measure `days` (not yet in the store): git for commits, GitHub for pull
/// requests and issues — a few searches for the whole span, not one per day.
pub fn measure(days: &[DayRef], repos: &[String]) -> HashMap<String, Day> {
    let Some(from) = days.iter().map(|d| d.start).reduce(f64::min) else { return HashMap::new() };
    let to = days.iter().map(|d| d.end).fold(from, f64::max);
    let mut out = tally(days, &commits(repos, from, to));
    // Search dates are days in UTC: a day wider on each side, then bucketed
    // by the local day of each timestamp.
    let range = format!("{}..{}", Local::with_offset(from - 86_400.0, 0).day_key(), Local::with_offset(to + 86_400.0, 0).day_key());
    let merged = gh_search(&format!("is:pr author:@me merged:{range}"), |i| {
        i.get("pull_request").and_then(|p| p.get("merged_at")).and_then(Value::as_str).map(str::to_string)
    });
    let opened = gh_search(&format!("is:pr author:@me created:{range}"), |i| i.get("created_at").and_then(Value::as_str).map(str::to_string));
    let closed_issues = {
        let closed_at = |i: &Value| i.get("closed_at").and_then(Value::as_str).map(str::to_string);
        match (gh_search(&format!("is:issue assignee:@me closed:{range}"), closed_at), gh_search(&format!("is:issue author:@me closed:{range}"), closed_at)) {
            (Some(mut a), Some(b)) => {
                let have: HashSet<String> = a.iter().map(|(u, _)| u.clone()).collect();
                a.extend(b.into_iter().filter(|(u, _)| !have.contains(u)));
                Some(a)
            }
            (a, b) => a.or(b),
        }
    };
    let (m, o, c) = (per_day(days, merged.as_deref()), per_day(days, opened.as_deref()), per_day(days, closed_issues.as_deref()));
    for (key, day) in out.iter_mut() {
        day.prs_merged = m.get(key).copied().flatten();
        day.prs_opened = o.get(key).copied().flatten();
        day.issues_closed = c.get(key).copied().flatten();
    }
    out
}

/// The repos to count: every repo the core knows, less First Mate's own
/// research repository.
pub fn repos(config_dir: &Path, listed: Vec<String>) -> Vec<String> {
    let mut set: Vec<String> = crate::discovery::RepoSet::open(config_dir.join(crate::discovery::FILE_NAME)).repos();
    for r in listed {
        if !set.contains(&r) {
            set.push(r);
        }
    }
    let research = std::env::var_os("HOME").map(PathBuf::from).map(|h| h.join("seahelm-research"));
    set.retain(|r| research.as_deref().map_or(true, |p| Path::new(r) != p));
    set
}

// MARK: the report

fn thousands(n: u64) -> String {
    let s = n.to_string();
    let mut out = String::new();
    for (i, ch) in s.chars().enumerate() {
        if i > 0 && (s.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    out
}

/// `▲40%` / `▼10%` / `=`; from nothing to something, `▲` alone.
fn change(now: u64, then: u64) -> String {
    match (now, then) {
        (a, b) if a == b => "=".into(),
        (a, 0) if a > 0 => "▲".into(),
        (a, b) if a > b => format!("▲{}%", ((a - b) as f64 / b as f64 * 100.0).round() as u64),
        (a, b) => format!("▼{}%", ((b - a) as f64 / b as f64 * 100.0).round() as u64),
    }
}

/// `▁▂▃▅▇` over the values.
pub fn sparkline(values: &[u64]) -> String {
    const BARS: [char; 8] = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
    let max = values.iter().copied().max().unwrap_or(0);
    values
        .iter()
        .map(|&v| if max == 0 { BARS[0] } else { BARS[((v as f64 / max as f64) * 7.0).round() as usize] })
        .collect()
}

fn weekday_name(w: u32, l: Lang) -> &'static str {
    let en = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    let zh = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
    match l {
        Lang::En => en[w as usize % 7],
        Lang::Zh => zh[w as usize % 7],
    }
}

fn lines_of(d: &Day) -> u64 {
    d.added + d.removed
}

fn sum<'a>(days: impl Iterator<Item = &'a Day>, f: impl Fn(&Day) -> u64) -> u64 {
    days.map(f).sum()
}

/// What the report is made of, already measured.
pub struct Report<'a> {
    pub lang: Lang,
    pub day: &'a DayRef,
    pub extra: &'a [DayRef],
    pub offset: i64,
    pub store: &'a Store,
}

/// The "yesterday's work" lines, or None when there is nothing to say (the
/// day and the weekend after it were empty, or already reported).
pub fn compose(r: &Report) -> Option<String> {
    let l = r.lang;
    let get = |d: &DayRef| r.store.days.get(&d.key).cloned().unwrap_or_default();
    let day = get(r.day);
    let extra: Vec<Day> = r.extra.iter().map(get).collect();
    let weekend_commits: u32 = extra.iter().map(|d| d.commits).sum();
    let weekend_lines: u64 = extra.iter().map(lines_of).sum();
    let weekend_prs: u32 = extra.iter().filter_map(|d| d.prs_merged).sum();
    let reported = r.store.reported_through.as_deref();
    let day_new = reported.map_or(true, |k| k < r.day.key.as_str());
    let weekend_new = r.extra.last().is_some_and(|d| reported.map_or(true, |k| k < d.key.as_str()))
        && (weekend_commits > 0 || weekend_prs > 0);
    let day_empty = day.commits == 0 && day.prs_merged.unwrap_or(0) == 0 && day.prs_opened.unwrap_or(0) == 0 && day.issues_closed.unwrap_or(0) == 0;
    if !(day_new && !day_empty) && !weekend_new {
        return None;
    }
    let prev = get(&r.day.previous_weekday(r.offset));
    let last_week = get(&r.day.week_before(r.offset));
    let prev_name = weekday_name(r.day.previous_weekday(r.offset).weekday, l);
    let mut out = Vec::new();
    // Monday's brief speaks of Friday: not "yesterday", and its week is
    // last week.
    let yesterday = r.extra.is_empty();
    let week_over = r.extra.iter().any(|d| d.weekday == 0);
    if day_new && !day_empty {
        let name = weekday_name(r.day.weekday, l);
        out.push(match (l, yesterday) {
            (Lang::En, true) => format!("Yesterday's work ({name} {}/{}):", r.day.month, r.day.day),
            (Lang::En, false) => format!("{name}'s work ({}/{}):", r.day.month, r.day.day),
            (Lang::Zh, true) => format!("昨日工作（{}月{}日 {name}）：", r.day.month, r.day.day),
            (Lang::Zh, false) => format!("{name}的工作（{}月{}日）：", r.day.month, r.day.day),
        });
    }
    if day_new && !day_empty {
        let vs = |now: u64, a: u64, b: u64| match l {
            Lang::En => format!("{} vs {prev_name}, {} vs last week", change(now, a), change(now, b)),
            Lang::Zh => format!("比{prev_name} {}，比上周同日 {}", change(now, a), change(now, b)),
        };
        out.push(match l {
            Lang::En => format!(
                "Code: {} · +{} / −{} · {} ({})",
                plural_en(day.commits as usize, "commit"), thousands(day.added), thousands(day.removed), plural_en(day.files as usize, "file"),
                vs(lines_of(&day), lines_of(&prev), lines_of(&last_week))
            ),
            Lang::Zh => format!(
                "代码：{} 次提交 · +{} / −{} · {} 个文件（{}）",
                day.commits, thousands(day.added), thousands(day.removed), day.files,
                vs(lines_of(&day), lines_of(&prev), lines_of(&last_week))
            ),
        });
        let top: Vec<String> = day.repos.iter().take(3).map(|p| format!("{} +{}/−{}", p.name, thousands(p.added), thousands(p.removed))).collect();
        if day.repos.len() > 1 {
            out.push(format!("  {}", top.join(" · ")));
        }
        let mut gh = Vec::new();
        if let Some(m) = day.prs_merged {
            let cmp = prev.prs_merged.map(|p| format!(" {}", change(m as u64, p as u64))).unwrap_or_default();
            gh.push(match l {
                Lang::En => format!("PRs merged {m}{cmp}"),
                Lang::Zh => format!("合并 PR {m}{cmp}"),
            });
        }
        if let Some(o) = day.prs_opened {
            gh.push(match l {
                Lang::En => format!("opened {o}"),
                Lang::Zh => format!("新开 {o}"),
            });
        }
        if let Some(c) = day.issues_closed {
            gh.push(match l {
                Lang::En => format!("issues closed {c}"),
                Lang::Zh => format!("关闭 issue {c}"),
            });
        }
        if !gh.is_empty() {
            out.push(format!("{}{}", l.pick("GitHub: ", "GitHub："), gh.join(" · ")));
        }
        // The week so far against the same days last week.
        let week = week_so_far(r.day, r.offset);
        if week.len() > 1 {
            let this: Vec<Day> = week.iter().map(get).collect();
            let before: Vec<Day> = week.iter().map(|d| get(&d.week_before(r.offset))).collect();
            let (c_now, c_then) = (sum(this.iter(), |d| d.commits as u64), sum(before.iter(), |d| d.commits as u64));
            let (p_now, p_then) = (sum(this.iter(), |d| d.prs_merged.unwrap_or(0) as u64), sum(before.iter(), |d| d.prs_merged.unwrap_or(0) as u64));
            out.push(match (l, week_over) {
                (Lang::En, false) => format!("This week: {} ({} vs the same days last week) · {} merged ({})", plural_en(c_now as usize, "commit"), change(c_now, c_then), plural_en(p_now as usize, "PR"), change(p_now, p_then)),
                (Lang::En, true) => format!("That week: {} ({} vs the week before) · {} merged ({})", plural_en(c_now as usize, "commit"), change(c_now, c_then), plural_en(p_now as usize, "PR"), change(p_now, p_then)),
                (Lang::Zh, false) => format!("本周：{c_now} 次提交（比上周同期 {}）· 合并 PR {p_now}（{}）", change(c_now, c_then), change(p_now, p_then)),
                (Lang::Zh, true) => format!("上周：{c_now} 次提交（比再上周 {}）· 合并 PR {p_now}（{}）", change(c_now, c_then), change(p_now, p_then)),
            });
        }
        let spark: Vec<u64> = last_weekdays(r.day, 7, r.offset).iter().map(|d| lines_of(&get(d))).collect();
        if spark.iter().any(|v| *v > 0) {
            out.push(format!("{}{}", l.pick("Lines, last 7 weekdays: ", "近 7 个工作日代码量："), sparkline(&spark)));
        }
        let wins = milestones(r, &day);
        if !wins.is_empty() {
            out.push(format!("🎉 {}", wins.join(" · ")));
        }
    }
    if weekend_new {
        out.push(match l {
            Lang::En => format!("Weekend: {} · {} lines · {} merged", plural_en(weekend_commits as usize, "commit"), thousands(weekend_lines), plural_en(weekend_prs as usize, "PR")),
            Lang::Zh => format!("周末：{weekend_commits} 次提交 · {} 行 · 合并 PR {weekend_prs}", thousands(weekend_lines)),
        });
    }
    Some(out.join("\n"))
}

/// What is worth celebrating about the day, from the days on record.
fn milestones(r: &Report, day: &Day) -> Vec<String> {
    let l = r.lang;
    let mut out = Vec::new();
    // Weekdays in a row, ending with the day, with a merged PR.
    let mut streak = 0;
    let mut d = r.day.clone();
    while r.store.days.get(&d.key).and_then(|x| x.prs_merged).unwrap_or(0) > 0 {
        streak += 1;
        d = d.previous_weekday(r.offset);
    }
    if streak >= 3 {
        out.push(match l {
            Lang::En => format!("{streak} weekdays in a row with a merged PR"),
            Lang::Zh => format!("连续 {streak} 个工作日有 PR 合并"),
        });
    }
    // A record, once there is a month to beat.
    let earlier: Vec<u64> = r.store.days.iter().filter(|(k, _)| k.as_str() < r.day.key.as_str()).map(|(_, x)| lines_of(x)).collect();
    if earlier.len() >= 20 && lines_of(day) > 0 && earlier.iter().all(|v| lines_of(day) > *v) {
        out.push(l.pick("most lines in a day on record", "单日代码量新高").to_string());
    }
    // This week already past all of last week, in merged PRs.
    let week = week_so_far(r.day, r.offset);
    let this: u64 = week.iter().filter_map(|d| r.store.days.get(&d.key)).map(|x| x.prs_merged.unwrap_or(0) as u64).sum();
    let monday_before = week[0].week_before(r.offset);
    let mut last = Vec::new();
    let mut d = monday_before;
    for _ in 0..5 {
        last.push(d.clone());
        d = DayRef::containing(d.end + 43_200.0, r.offset);
    }
    let complete = last.iter().all(|d| r.store.days.get(&d.key).is_some_and(|x| x.prs_merged.is_some()));
    let last_total: u64 = last.iter().filter_map(|d| r.store.days.get(&d.key)).map(|x| x.prs_merged.unwrap_or(0) as u64).sum();
    if complete && r.day.weekday < 5 && last_total > 0 && this > last_total {
        out.push(match l {
            Lang::En => format!("{this} PRs merged this week, past all of last week ({last_total})"),
            Lang::Zh => format!("本周已合并 {this} 个 PR，超过上周全周（{last_total}）"),
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const UTC8: i64 = 8 * 3600;

    /// Noon, local (UTC+8), on 2026-11-`d`.
    fn noon(d: u32) -> f64 {
        crate::usage::parse_iso8601(&format!("2026-11-{d:02}T04:00:00Z")).unwrap()
    }

    #[test]
    fn the_report_is_about_the_last_weekday() {
        // 2026-11-17 is a Tuesday: the report is Monday's, nothing extra.
        let (day, extra) = report_days(noon(17), UTC8);
        assert_eq!((day.key.as_str(), day.weekday), ("2026-11-16", 1));
        assert!(extra.is_empty());
        // Monday: Friday, with the weekend after it.
        let (day, extra) = report_days(noon(16), UTC8);
        assert_eq!(day.key, "2026-11-13");
        assert_eq!(extra.iter().map(|d| d.key.as_str()).collect::<Vec<_>>(), ["2026-11-14", "2026-11-15"]);
        // Monday compares with Friday; a week before is the same weekday.
        let mon = DayRef::containing(noon(16), UTC8);
        assert_eq!(mon.previous_weekday(UTC8).key, "2026-11-13");
        assert_eq!(mon.week_before(UTC8).key, "2026-11-09");
    }

    #[test]
    fn days_needed_covers_comparisons_week_and_sparkline() {
        let (day, extra) = report_days(noon(19), UTC8); // Thursday: Wednesday the 18th
        let keys: Vec<String> = days_needed(&day, &extra, UTC8).into_iter().map(|d| d.key).collect();
        for k in ["2026-11-18", "2026-11-17", "2026-11-11", "2026-11-16", "2026-11-09", "2026-11-10"] {
            assert!(keys.contains(&k.to_string()), "{k} in {keys:?}");
        }
        assert!(keys.windows(2).all(|w| w[0] < w[1]), "sorted, each once");
    }

    #[test]
    fn parses_log_with_numstat_and_binary_files() {
        let text = "@aaa 1763000000 me@x.com\n10\t2\tsrc/a.rs\n-\t-\tlogo.png\n\n@bbb 1763000100 noreply@github.com\n5\t5\tb.rs\n";
        let c = parse_log(text);
        assert_eq!(c.len(), 2);
        assert_eq!((c[0].added, c[0].removed, c[0].files), (10, 2, 2));
        assert!(made_on_github(&c[1]) && !made_on_github(&c[0]));
    }

    #[test]
    fn counts_the_users_commits_once_and_skips_github_squashes() {
        let tmp = tempfile::Builder::new().prefix("stats").tempdir().unwrap();
        let repo = tmp.path().join("proj");
        std::fs::create_dir_all(&repo).unwrap();
        let run = |args: &[&str], email: &str, committer: &str| {
            let ok = Command::new("git").arg("-C").arg(&repo).args(args)
                .env("GIT_AUTHOR_NAME", "u").env("GIT_AUTHOR_EMAIL", email)
                .env("GIT_COMMITTER_NAME", "c").env("GIT_COMMITTER_EMAIL", committer)
                .output().unwrap().status.success();
            assert!(ok, "{args:?}");
        };
        run(&["init", "-q", "-b", "main"], "me@x.com", "me@x.com");
        run(&["config", "user.email", "me@x.com"], "me@x.com", "me@x.com");
        std::fs::write(repo.join("a.txt"), "1\n2\n3\n").unwrap();
        run(&["add", "."], "me@x.com", "me@x.com");
        run(&["commit", "-q", "-m", "mine"], "me@x.com", "me@x.com");
        std::fs::write(repo.join("b.txt"), "x\n").unwrap();
        run(&["add", "."], "me@x.com", "me@x.com");
        run(&["commit", "-q", "-m", "squash on github"], "me@x.com", "noreply@github.com");
        std::fs::write(repo.join("c.txt"), "y\n").unwrap();
        run(&["add", "."], "other@x.com", "other@x.com");
        run(&["commit", "-q", "-m", "someone else"], "other@x.com", "other@x.com");
        let now = crate::usage::now();
        let r = repo.to_string_lossy().into_owned();
        let got = commits(&[r.clone(), r], now - 3600.0, now + 3600.0);
        assert_eq!(got.len(), 1, "{got:?}");
        assert_eq!((got[0].0.as_str(), got[0].1.added), ("proj", 3));
    }

    fn day(commits: u32, added: u64, removed: u64, merged: u32) -> Day {
        Day { commits, added, removed, files: commits * 2, prs_merged: Some(merged), prs_opened: Some(1), issues_closed: Some(0), repos: vec![] }
    }

    #[test]
    fn composes_comparisons_week_sparkline_and_milestones() {
        let (d, extra) = report_days(noon(19), UTC8); // Wed 18th
        let mut store = Store::default();
        store.days.insert("2026-11-11".into(), day(4, 100, 0, 1)); // a week before
        store.days.insert("2026-11-09".into(), day(2, 50, 0, 1));
        store.days.insert("2026-11-10".into(), day(2, 50, 0, 1));
        store.days.insert("2026-11-16".into(), day(3, 80, 20, 2));
        store.days.insert("2026-11-17".into(), day(5, 90, 10, 1)); // the day before: 100 lines
        let mut wed = day(6, 120, 30, 3); // 150 lines
        wed.repos = vec![
            RepoDay { name: "olap".into(), commits: 4, added: 100, removed: 20 },
            RepoDay { name: "seahelm".into(), commits: 2, added: 20, removed: 10 },
        ];
        store.days.insert("2026-11-18".into(), wed);
        let text = compose(&Report { lang: Lang::Zh, day: &d, extra: &extra, offset: UTC8, store: &store }).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[0], "昨日工作（11月18日 周三）：");
        assert_eq!(lines[1], "代码：6 次提交 · +120 / −30 · 12 个文件（比周二 ▲50%，比上周同日 ▲50%）");
        assert_eq!(lines[2], "  olap +100/−20 · seahelm +20/−10");
        assert_eq!(lines[3], "GitHub：合并 PR 3 ▲200% · 新开 1 · 关闭 issue 0");
        assert_eq!(lines[4], "本周：14 次提交（比上周同期 ▲75%）· 合并 PR 6（▲100%）");
        assert!(lines[5].starts_with("近 7 个工作日代码量："), "{}", lines[5]);
        assert_eq!(lines[6], "🎉 连续 3 个工作日有 PR 合并");
        let en = compose(&Report { lang: Lang::En, day: &d, extra: &extra, offset: UTC8, store: &store }).unwrap();
        assert!(en.starts_with("Yesterday's work (Wed 11/18):\nCode: 6 commits · +120 / −30 · 12 files (▲50% vs Tue, ▲50% vs last week)"), "{en}");
    }

    #[test]
    fn nothing_to_say_twice_or_about_an_empty_day() {
        let (d, extra) = report_days(noon(19), UTC8);
        let mut store = Store::default();
        assert!(compose(&Report { lang: Lang::En, day: &d, extra: &extra, offset: UTC8, store: &store }).is_none(), "an empty day");
        store.days.insert(d.key.clone(), day(1, 5, 0, 0));
        assert!(compose(&Report { lang: Lang::En, day: &d, extra: &extra, offset: UTC8, store: &store }).is_some());
        store.reported_through = Some(d.key.clone());
        assert!(compose(&Report { lang: Lang::En, day: &d, extra: &extra, offset: UTC8, store: &store }).is_none(), "already reported");
    }

    #[test]
    fn monday_adds_the_weekend_when_something_happened() {
        let (d, extra) = report_days(noon(16), UTC8); // Monday: Friday 13th + weekend
        let mut store = Store::default();
        store.days.insert("2026-11-13".into(), day(2, 10, 0, 1));
        store.days.insert("2026-11-15".into(), day(3, 40, 2, 1));
        let text = compose(&Report { lang: Lang::En, day: &d, extra: &extra, offset: UTC8, store: &store }).unwrap();
        assert!(text.starts_with("Fri's work (11/13):"), "{text}");
        assert!(text.ends_with("Weekend: 3 commits · 42 lines · 1 PR merged"), "{text}");
        let zh = compose(&Report { lang: Lang::Zh, day: &d, extra: &extra, offset: UTC8, store: &store }).unwrap();
        assert!(zh.starts_with("周五的工作（11月13日）："), "{zh}");
        assert!(zh.contains("\n上周："), "{zh}");
        // Friday reported on Saturday's brief: Monday still tells the weekend.
        store.reported_through = Some("2026-11-13".into());
        let text = compose(&Report { lang: Lang::En, day: &d, extra: &extra, offset: UTC8, store: &store }).unwrap();
        assert_eq!(text, "Weekend: 3 commits · 42 lines · 1 PR merged");
    }

    #[test]
    fn changes_and_sparklines_read_right() {
        assert_eq!(change(150, 100), "▲50%");
        assert_eq!(change(50, 100), "▼50%");
        assert_eq!(change(3, 0), "▲");
        assert_eq!(change(0, 0), "=");
        assert_eq!(sparkline(&[0, 1, 2, 4, 8]), "▁▂▃▅█");
        assert_eq!(sparkline(&[0, 0]), "▁▁");
        assert_eq!(thousands(1234567), "1,234,567");
    }
}

