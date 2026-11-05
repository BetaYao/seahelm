//! The fleet: every project's worktrees, read from git on this machine.
//!
//! The client has no app behind it: the projects are its own list
//! (`~/.config/seahelm/gpui-projects.json`, added with the folder button),
//! their worktrees come from `git worktree list`, and what each one is doing
//! from seahelm-core, which the workspace lays over the rows. Grouping is
//! done here, from that. Git stats are worked out on a thread of their own
//! from each worktree's checkout.

use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Item {
    /// The worktree's path, which is also its id.
    pub id: String,
    pub title: String,
    /// The second line: the worktree's name ("main" for the main checkout).
    pub subtitle: String,
    pub branch: String,
    pub repository: String,
    /// seahelm-core's status word ("Running", "Idle", …), empty when the
    /// core has no pane there.
    pub status: String,
    pub worktree_path: String,
    pub last_activity_at: Option<f64>,
    pub running_since: Option<f64>,
    pub unseen: bool,
    /// The project's main checkout, which is never deleted.
    pub is_main: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Group {
    pub title: String,
    /// The project's main checkout, for a group that is one project
    /// (grouped by repository); empty otherwise.
    pub path: String,
    pub items: Vec<Item>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GitStats {
    pub added: u64,
    pub removed: u64,
    pub ahead: u64,
    pub behind: u64,
}

/// One reading of the fleet: projects and their worktrees, as git has
/// them.
#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    pub groups: Vec<Group>,
    /// Why there is no fleet, when there is none.
    pub error: Option<String>,
}

impl Snapshot {
    pub fn worktree_count(&self) -> usize {
        self.groups.iter().map(|g| g.items.len()).sum()
    }

    pub fn find(&self, id: &str) -> Option<&Item> {
        self.groups.iter().flat_map(|g| g.items.iter()).find(|i| i.id == id)
    }
}

/// How the fleet column groups worktrees (the app's `WorktreeGroupingMode`,
/// less the pane mode).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Grouping {
    #[default]
    Repository,
    Status,
    Activity,
}

impl Grouping {
    pub fn next(self) -> Self {
        match self {
            Grouping::Repository => Grouping::Status,
            Grouping::Status => Grouping::Activity,
            Grouping::Activity => Grouping::Repository,
        }
    }
}

/// What a row shows for an item's status.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dot {
    Running,
    Waiting,
    Idle,
    Error,
    Exited,
    Unknown,
    Unseen,
}

impl Item {
    pub fn dot(&self) -> Dot {
        if self.unseen {
            return Dot::Unseen;
        }
        match self.status.as_str() {
            "Running" => Dot::Running,
            "Waiting" | "Blocked" | "NeedsInput" => Dot::Waiting,
            "Idle" => Dot::Idle,
            "Error" => Dot::Error,
            "Exited" => Dot::Exited,
            _ => Dot::Unknown,
        }
    }

    /// The time label: how long it has run, while running; else how long ago
    /// it last did anything (`WorktreeRowHelpers.swift`).
    pub fn time_label(&self, now: f64) -> String {
        if self.dot() == Dot::Running {
            if let Some(since) = self.running_since {
                return compact_duration((now - since).max(0.0));
            }
        }
        match self.last_activity_at {
            Some(at) => relative_age((now - at).max(0.0)),
            None => String::new(),
        }
    }
}

pub fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// "12s", "3m05s", "1h02m".
pub fn compact_duration(secs: f64) -> String {
    let s = secs as u64;
    if s < 60 {
        format!("{s}s")
    } else if s < 3600 {
        format!("{}m{:02}s", s / 60, s % 60)
    } else {
        format!("{}h{:02}m", s / 3600, (s % 3600) / 60)
    }
}

/// "just now", "Ns", "Nm", "Nh", "Nd".
pub fn relative_age(secs: f64) -> String {
    let s = secs as u64;
    if s < 10 {
        "just now".into()
    } else if s < 60 {
        format!("{s}s")
    } else if s < 3600 {
        format!("{}m", s / 60)
    } else if s < 86400 {
        format!("{}h", s / 3600)
    } else {
        format!("{}d", s / 86400)
    }
}

/// The projects: this client's own list.
pub fn projects() -> Vec<String> {
    std::fs::read_to_string(projects_file()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

fn projects_file() -> std::path::PathBuf {
    crate::platform::config_dir().join("gpui-projects.json")
}

/// Add a project (a directory in a git repository) to the list.
pub fn add_project(path: &str) -> Result<(), String> {
    git(path, &["rev-parse", "--show-toplevel"]).ok_or_else(|| format!("{path} is not in a git repository"))?;
    let mut list = projects();
    if !list.iter().any(|p| p == path) {
        list.push(path.to_string());
    }
    std::fs::create_dir_all(crate::platform::config_dir()).map_err(|e| e.to_string())?;
    let text = serde_json::to_string_pretty(&list).map_err(|e| e.to_string())?;
    std::fs::write(projects_file(), text).map_err(|e| e.to_string())
}

/// Take a project off the list (its worktrees stay on disk).
pub fn remove_project(path: &str) -> Result<(), String> {
    let list: Vec<String> = projects().into_iter().filter(|p| p != path).collect();
    let text = serde_json::to_string_pretty(&list).map_err(|e| e.to_string())?;
    std::fs::write(projects_file(), text).map_err(|e| e.to_string())
}

/// `git worktree list --porcelain`: each worktree's path and branch.
pub fn parse_worktrees(porcelain: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut path: Option<String> = None;
    let mut branch = String::new();
    for line in porcelain.lines().chain(std::iter::once("")) {
        if let Some(p) = line.strip_prefix("worktree ") {
            path = Some(p.to_string());
            branch.clear();
        } else if let Some(b) = line.strip_prefix("branch ") {
            branch = b.trim_start_matches("refs/heads/").to_string();
        } else if line == "detached" {
            branch = "detached".into();
        } else if line.is_empty() {
            if let Some(p) = path.take() {
                out.push((p, std::mem::take(&mut branch)));
            }
        }
    }
    out
}

fn base_name(path: &str) -> String {
    std::path::Path::new(path).file_name().and_then(|n| n.to_str()).unwrap_or(path).to_string()
}

/// The fleet from git: one group per project, its worktrees as rows, the
/// main checkout first.
pub fn read() -> Snapshot {
    let projects = projects();
    if projects.is_empty() {
        return Snapshot { error: Some("No projects yet. Add one with the folder button above.".into()), ..Snapshot::default() };
    }
    let mut groups = Vec::new();
    for project in projects {
        let name = base_name(&project);
        let Some(list) = git(&project, &["worktree", "list", "--porcelain"]) else { continue };
        let items: Vec<Item> = parse_worktrees(&list)
            .into_iter()
            .enumerate()
            .map(|(i, (path, branch))| Item {
                id: path.clone(),
                // The app's rows: a session title from the core wins, else the
                // branch; the second line is the worktree's name, "main" for
                // the main checkout.
                title: if branch.is_empty() || branch == "detached" { base_name(&path) } else { branch.clone() },
                subtitle: if i == 0 { "main".to_string() } else { base_name(&path) },
                branch: branch.clone(),
                repository: name.clone(),
                worktree_path: path,
                is_main: i == 0,
                ..Item::default()
            })
            .collect();
        let items = by_creation(items);
        groups.push(Group { title: name, path: project.clone(), items });
    }
    Snapshot { groups, error: None }
}

/// The groups the column shows: by project as read, by status (the
/// app's order: needs input, finished, running, idle, error, dormant,
/// unknown; newest activity first within each), or by when each last did
/// anything.
pub fn regroup(groups: &[Group], mode: Grouping, now: f64) -> Vec<Group> {
    if mode == Grouping::Repository {
        return groups.to_vec();
    }
    let mut items: Vec<Item> = groups.iter().flat_map(|g| g.items.iter().cloned()).collect();
    items.sort_by(|a, b| b.last_activity_at.unwrap_or(0.0).total_cmp(&a.last_activity_at.unwrap_or(0.0)));
    let titles: &[&str] = match mode {
        Grouping::Status => &["Needs input", "Finished", "Running", "Idle", "Error", "Dormant", "Unknown"],
        _ => &["Recent hour", "Today", "Recent 7 days", "Earlier", "No activity"],
    };
    let bucket = |i: &Item| -> usize {
        match mode {
            Grouping::Status => match i.dot() {
                Dot::Waiting => 0,
                Dot::Unseen => 1,
                Dot::Running => 2,
                Dot::Idle => 3,
                Dot::Error => 4,
                Dot::Exited => 5,
                Dot::Unknown => 6,
            },
            _ => match i.last_activity_at.map(|at| (now - at).max(0.0)) {
                Some(age) if age < 3600.0 => 0,
                Some(age) if age < 86400.0 => 1,
                Some(age) if age < 7.0 * 86400.0 => 2,
                Some(_) => 3,
                None => 4,
            },
        }
    };
    let mut out: Vec<Group> = titles.iter().map(|t| Group { title: t.to_string(), path: String::new(), items: Vec::new() }).collect();
    for item in items {
        let b = bucket(&item);
        out[b].items.push(item);
    }
    out.retain(|g| !g.items.is_empty());
    out
}

/// The app's order: the main checkout first, then the rest oldest first by
/// when their directory was made. A filesystem that keeps no creation time
/// leaves git's order.
fn by_creation(mut items: Vec<Item>) -> Vec<Item> {
    if items.len() < 3 {
        return items;
    }
    let rest = items.split_off(1);
    let mut dated: Vec<(Option<std::time::SystemTime>, Item)> =
        rest.into_iter().map(|i| (std::fs::metadata(&i.worktree_path).and_then(|m| m.created()).ok(), i)).collect();
    if dated.iter().all(|(t, _)| t.is_some()) {
        dated.sort_by_key(|(t, _)| *t);
    }
    items.extend(dated.into_iter().map(|(_, i)| i));
    items
}

fn git(path: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("git").arg("-C").arg(path).args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// What this worktree changes against where it branched from (the default
/// branch), uncommitted work included; and where it stands to its upstream.
pub fn git_stats(path: &str) -> Option<GitStats> {
    let base = git(path, &["rev-parse", "--abbrev-ref", "origin/HEAD"]).unwrap_or_else(|| "main".into());
    let fork = git(path, &["merge-base", "HEAD", &base]).unwrap_or_else(|| "HEAD".into());
    let short = git(path, &["diff", "--shortstat", &fork])?;
    let mut stats = GitStats::default();
    for part in short.split(',') {
        let part = part.trim();
        let n: u64 = part.split_whitespace().next().and_then(|n| n.parse().ok()).unwrap_or(0);
        if part.contains("insertion") {
            stats.added = n;
        } else if part.contains("deletion") {
            stats.removed = n;
        }
    }
    if let Some(counts) = git(path, &["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]) {
        let mut it = counts.split_whitespace().filter_map(|n| n.parse().ok());
        stats.ahead = it.next().unwrap_or(0);
        stats.behind = it.next().unwrap_or(0);
    }
    Some(stats)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn times_read_as_the_app_writes_them() {
        assert_eq!(relative_age(3.0), "just now");
        assert_eq!(relative_age(42.0), "42s");
        assert_eq!(relative_age(125.0), "2m");
        assert_eq!(relative_age(7300.0), "2h");
        assert_eq!(relative_age(200000.0), "2d");
        assert_eq!(compact_duration(12.0), "12s");
        assert_eq!(compact_duration(185.0), "3m05s");
        assert_eq!(compact_duration(3720.0), "1h02m");
    }

    #[test]
    fn worktree_lists_parse() {
        let porcelain = "worktree /r/main\nHEAD abc\nbranch refs/heads/main\n\nworktree /r/wt-a\nHEAD def\nbranch refs/heads/feat/a\n\nworktree /r/wt-b\nHEAD 123\ndetached\n";
        assert_eq!(
            parse_worktrees(porcelain),
            vec![
                ("/r/main".to_string(), "main".to_string()),
                ("/r/wt-a".to_string(), "feat/a".to_string()),
                ("/r/wt-b".to_string(), "detached".to_string()),
            ]
        );
    }

    fn item(id: &str, status: &str, unseen: bool, last: Option<f64>) -> Item {
        Item { id: id.into(), status: status.into(), unseen, last_activity_at: last, ..Item::default() }
    }

    #[test]
    fn grouping_by_status_follows_the_apps_order() {
        let groups = vec![Group {
            path: String::new(),
            title: "p".into(),
            items: vec![
                item("idle", "Idle", false, Some(10.0)),
                item("run-old", "Running", false, Some(5.0)),
                item("waiting", "Waiting", false, None),
                item("run-new", "Running", false, Some(20.0)),
                item("done", "Idle", true, Some(1.0)),
                item("none", "", false, None),
            ],
        }];
        let out = regroup(&groups, Grouping::Status, 100.0);
        let shape: Vec<(String, Vec<String>)> =
            out.iter().map(|g| (g.title.clone(), g.items.iter().map(|i| i.id.clone()).collect())).collect();
        assert_eq!(
            shape,
            vec![
                ("Needs input".into(), vec!["waiting".into()]),
                ("Finished".into(), vec!["done".into()]),
                ("Running".into(), vec!["run-new".into(), "run-old".into()]),
                ("Idle".into(), vec!["idle".into()]),
                ("Unknown".into(), vec!["none".into()]),
            ]
        );
    }

    #[test]
    fn grouping_by_activity_buckets_by_age() {
        let now = 10.0 * 86400.0;
        let groups = vec![Group {
            path: String::new(),
            title: "p".into(),
            items: vec![
                item("hour", "", false, Some(now - 60.0)),
                item("day", "", false, Some(now - 7200.0)),
                item("week", "", false, Some(now - 3.0 * 86400.0)),
                item("old", "", false, Some(now - 9.0 * 86400.0)),
                item("never", "", false, None),
            ],
        }];
        let titles: Vec<String> = regroup(&groups, Grouping::Activity, now).into_iter().map(|g| g.title).collect();
        assert_eq!(titles, vec!["Recent hour", "Today", "Recent 7 days", "Earlier", "No activity"]);
    }
}
