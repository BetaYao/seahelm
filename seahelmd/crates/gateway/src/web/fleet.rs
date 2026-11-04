//! `fleet.groups` for seahelm-web: the worktree rows the desktop dashboard
//! draws, grouped by repository, status or activity time, built from the
//! core's `worktree.list` and `pane.list`. The rules are the dashboard's
//! (`WorktreeGrouping`): status groups in priority order with unread
//! finished work under "Needs input", activity in five buckets.

use std::collections::HashMap;

use serde_json::{json, Value};

/// `rows`: core `worktree.list` worktrees; `panes`: core `pane.list` panes.
pub fn groups(mode: &str, worktrees: &[Value], panes: &[Value], now: f64) -> Value {
    let mut project_of: HashMap<&str, &str> = HashMap::new();
    let mut first_mates: Vec<&str> = Vec::new();
    for p in panes {
        let Some(w) = p["worktree_path"].as_str() else { continue };
        if p["pane_session_key"].as_str() == Some(super::FIRST_MATE) {
            first_mates.push(w);
            continue;
        }
        if let Some(proj) = p["project"].as_str() {
            project_of.entry(w).or_insert(proj);
        }
    }
    let items: Vec<Value> = worktrees
        .iter()
        .filter_map(|w| {
            let path = w["worktree_path"].as_str()?;
            // First Mate's own directory is not a row.
            if first_mates.contains(&path) && !project_of.contains_key(path) {
                return None;
            }
            let repo = project_of.get(path).copied().filter(|p| !p.is_empty()).unwrap_or("Unknown project");
            let mut item = json!({
                "id": path, "worktree_path": path, "repository": repo,
                "status": w["group_status"].as_str().or(w["status"].as_str()).unwrap_or("Unknown"),
                "is_main_worktree": std::path::Path::new(path).join(".git").is_dir(),
            });
            for k in ["last_activity_at", "running_since", "title", "pr"] {
                if !w[k].is_null() {
                    item[k] = w[k].clone();
                }
            }
            if w["unseen"].as_bool() == Some(true) {
                item["unseen"] = json!(true);
            }
            Some(item)
        })
        .collect();
    let groups = match mode {
        "status" => status_groups(items),
        "activity" | "activitytime" | "time" => activity_groups(items, now),
        _ => repository_groups(items),
    };
    let mode = match mode {
        "status" => "status",
        "activity" | "activitytime" | "time" => "activity",
        "pane" => "pane",
        _ => "repository",
    };
    json!({"mode": mode, "groups": groups})
}

fn activity(i: &Value) -> Option<f64> {
    i["last_activity_at"].as_f64()
}

fn by_activity(a: &Value, b: &Value) -> std::cmp::Ordering {
    match (activity(a), activity(b)) {
        (Some(x), Some(y)) if x != y => y.total_cmp(&x),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        _ => a["worktree_path"].as_str().cmp(&b["worktree_path"].as_str()),
    }
}

fn repository_groups(items: Vec<Value>) -> Vec<Value> {
    let mut order: Vec<String> = Vec::new();
    let mut by: HashMap<String, Vec<Value>> = HashMap::new();
    for i in items {
        let r = i["repository"].as_str().unwrap_or("").to_string();
        if !by.contains_key(&r) {
            order.push(r.clone());
        }
        by.entry(r).or_default().push(i);
    }
    order
        .into_iter()
        .map(|r| {
            let mut list = by.remove(&r).unwrap_or_default();
            // Main first, then the order the worktrees were made in (path as
            // the stand-in: the core lists them in the client's order).
            list.sort_by_key(|i| !i["is_main_worktree"].as_bool().unwrap_or(false));
            json!({"id": format!("repository:{r}"), "title": r, "items": list})
        })
        .collect()
}

fn unseen_finish(i: &Value) -> bool {
    i["unseen"].as_bool() == Some(true) && i["status"].as_str() == Some("Idle")
}

fn status_groups(items: Vec<Value>) -> Vec<Value> {
    let order = [("Waiting", "Needs input"), ("Running", "Running"), ("Idle", "Idle"), ("Error", "Error"), ("Exited", "Dormant"), ("Unknown", "Unknown")];
    let mut groups: Vec<Value> = order
        .iter()
        .filter_map(|(status, title)| {
            let mut list: Vec<Value> = items.iter().filter(|i| i["status"].as_str() == Some(status) && !unseen_finish(i)).cloned().collect();
            if list.is_empty() {
                return None;
            }
            list.sort_by(by_activity);
            Some(json!({"id": format!("status:{status}"), "title": title, "status": status, "items": list}))
        })
        .collect();
    let mut finished: Vec<Value> = items.iter().filter(|i| unseen_finish(i)).cloned().collect();
    if !finished.is_empty() {
        finished.sort_by(by_activity);
        let at = usize::from(groups.first().and_then(|g| g["id"].as_str()) == Some("status:Waiting"));
        groups.insert(at, json!({"id": "status:unseen", "title": "Finished", "status": "Idle", "unseen": true, "items": finished}));
    }
    groups
}

fn activity_groups(items: Vec<Value>, now: f64) -> Vec<Value> {
    let buckets = [("recentHour", "Recent hour"), ("today", "Today"), ("recentSevenDays", "Recent 7 days"), ("earlier", "Earlier"), ("noActivity", "No activity")];
    let day_start = local_day_start(now);
    let bucket = |i: &Value| match activity(i) {
        None => "noActivity",
        Some(t) => {
            let age = (now - t).max(0.0);
            if age < 3600.0 {
                "recentHour"
            } else if t >= day_start {
                "today"
            } else if age < 7.0 * 86400.0 {
                "recentSevenDays"
            } else {
                "earlier"
            }
        }
    };
    buckets
        .iter()
        .filter_map(|(id, title)| {
            let mut list: Vec<Value> = items.iter().filter(|i| bucket(i) == *id).cloned().collect();
            if list.is_empty() {
                return None;
            }
            list.sort_by(by_activity);
            Some(json!({"id": format!("activity:{id}"), "title": title, "items": list}))
        })
        .collect()
}

/// Midnight today, local time, in seconds since the epoch.
fn local_day_start(now: f64) -> f64 {
    #[cfg(unix)]
    {
        let t = now as libc::time_t;
        let mut tm: libc::tm = unsafe { std::mem::zeroed() };
        // SAFETY: both pointers are to live locals.
        if !unsafe { libc::localtime_r(&t, &mut tm) }.is_null() {
            let since_midnight = tm.tm_hour as f64 * 3600.0 + tm.tm_min as f64 * 60.0 + tm.tm_sec as f64;
            return now - since_midnight - now.fract();
        }
    }
    now - now.rem_euclid(86400.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_mode_puts_unread_finished_under_needs_input() {
        let wts = vec![
            json!({"worktree_path": "/a", "group_status": "Waiting", "last_activity_at": 10.0}),
            json!({"worktree_path": "/b", "group_status": "Idle", "unseen": true, "last_activity_at": 20.0}),
            json!({"worktree_path": "/c", "group_status": "Running"}),
        ];
        let panes = vec![json!({"worktree_path": "/a", "project": "p"})];
        let g = groups("status", &wts, &panes, 100.0);
        let ids: Vec<&str> = g["groups"].as_array().unwrap().iter().map(|g| g["id"].as_str().unwrap()).collect();
        assert_eq!(ids, vec!["status:Waiting", "status:unseen", "status:Running"]);
        let r = groups("repository", &wts, &panes, 100.0);
        assert_eq!(r["groups"][0]["title"], "p");
        assert_eq!(r["groups"][1]["title"], "Unknown project");
        let a = groups("activity", &wts, &panes, 100.0);
        assert_eq!(a["groups"][0]["id"], "activity:recentHour");
        assert_eq!(a["groups"].as_array().unwrap().last().unwrap()["id"], "activity:noActivity");
    }
}
