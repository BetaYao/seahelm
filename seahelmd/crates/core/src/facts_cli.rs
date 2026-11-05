//! `seahelm-core facts <worktree> [--json]`: every fact First Mate would
//! put on a delete card for the worktree, measured now. Read-only, and needs
//! no running core: busy panes and pane activity come from one if it
//! answers; the PR from `gh` (any age, by head branch), else from a core's
//! `pr.list`, else "PR unknown". A PR head missing locally is not fetched
//! unless `--fetch` is given (objects only, no ref written); without it,
//! `unpushed_checked_pr_head` says whether the head could be used.

use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

use anyhow::{bail, Result};
use serde_json::{json, Value};

use crate::first_mate::facts::{git, Context, Facts, PrInfo};
use crate::pr::{self, PrStatus};
use crate::rpc;

pub fn run(args: &[String]) -> Result<()> {
    let json_out = args.iter().any(|a| a == "--json");
    let fetch = args.iter().any(|a| a == "--fetch");
    let Some(path) = args.iter().find(|a| !a.starts_with("--")) else { bail!("usage: facts <worktree-path> [--json] [--fetch]") };
    let path = std::fs::canonicalize(path)?;
    let path_str = path.to_string_lossy().to_string();
    if git(&path, &["rev-parse", "--git-dir"]).is_none() {
        bail!("{path_str} is not a git worktree");
    }
    let branch = git(&path, &["rev-parse", "--abbrev-ref", "HEAD"]).map(|b| b.trim().to_string()).filter(|b| b != "HEAD");

    let core = rpc::core_socket();
    let ask = |method: &str, params: Value| rpc::call_with_timeout(&core, method, params, Duration::from_secs(2)).ok();
    let panes = ask("pane.list", json!({"detail": true}));
    let (pr, pr_source) = match branch.as_deref().map(|b| from_gh(&path, b)) {
        Some(Some(found)) => (found, "gh"),
        _ => match ask("pr.list", json!({})).map(|v| from_core(&v, &path_str)) {
            Some(found) => (found, "core"),
            None => (None, "unknown"),
        },
    };
    let pr_info = match (&pr, pr_source) {
        (_, "unknown") => PrInfo::Unknown,
        (Some(p), _) => PrInfo::Some(p),
        (None, _) => PrInfo::None,
    };

    let mut ctx = Context::new(pr_info, seahelm_core_types::now());
    ctx.fetch_pr_head = fetch;
    if let Some(v) = &panes {
        let mine: Vec<&Value> = v
            .get("panes")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter(|p| p.get("worktree_path").and_then(Value::as_str) == Some(path_str.as_str())).collect())
            .unwrap_or_default();
        let status = |p: &Value| p.get("status").and_then(Value::as_str).unwrap_or_default().to_ascii_lowercase();
        ctx.busy_panes = mine.iter().filter(|p| matches!(status(p).as_str(), "running" | "waiting")).count() as u32;
        // `detail` puts the pane's own record under `info`.
        ctx.last_pane_activity = mine
            .iter()
            .flat_map(|p| ["last_user_prompt_at", "last_assistant_message_at", "started_at"].map(|k| p.pointer(&format!("/info/{k}")).and_then(Value::as_f64)))
            .flatten()
            .fold(None, |a: Option<f64>, t| Some(a.map_or(t, |a| a.max(t))));
    }
    let facts = Facts::measure(&path, &ctx);

    if json_out {
        let mut v = serde_json::to_value(&facts)?;
        v["worktree"] = json!(path_str);
        v["branch"] = json!(branch);
        v["pr_source"] = json!(pr_source);
        v["panes_source"] = json!(if panes.is_some() { "core" } else { "none" });
        v["summary"] = json!(facts.summary());
        println!("{}", serde_json::to_string_pretty(&v)?);
    } else {
        println!("{path_str} ({})", branch.as_deref().unwrap_or("detached"));
        println!("  {}", facts.summary());
        let v = serde_json::to_value(&facts)?;
        for (k, val) in v.as_object().into_iter().flatten() {
            println!("  {k:<26} {val}");
        }
        println!("  {:<26} {pr_source}", "pr_source");
        println!("  {:<26} {}", "panes_source", if panes.is_some() { "core" } else { "none (no core answered)" });
    }
    Ok(())
}

/// The branch's newest PR in `origin`'s repository, through `gh`.
/// Some(None) when GitHub has none; None when `gh` could not say.
fn from_gh(path: &Path, branch: &str) -> Option<Option<PrStatus>> {
    let remote = git(path, &["remote", "get-url", "origin"])?;
    let repo = pr::github_repo(&remote)?;
    let owner = repo.split('/').next()?.to_string();
    let out = Command::new("gh")
        .current_dir(path)
        .args(["pr", "list", "--repo", &repo, "--head", branch, "--state", "all", "--limit", "10"])
        .args(["--json", "number,url,state,isDraft,headRefOid,mergedAt,headRepositoryOwner,updatedAt"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let mut list: Vec<Value> = serde_json::from_slice(&out.stdout).ok()?;
    list.retain(|n| n.pointer("/headRepositoryOwner/login").and_then(Value::as_str).is_some_and(|o| o.eq_ignore_ascii_case(&owner)));
    list.sort_by(|a, b| b.get("updatedAt").and_then(Value::as_str).cmp(&a.get("updatedAt").and_then(Value::as_str)));
    let Some(n) = list.first() else { return Some(None) };
    let draft = n.get("isDraft").and_then(Value::as_bool).unwrap_or(false);
    Some(Some(PrStatus { body: String::new(),
        number: n.get("number").and_then(Value::as_u64)?,
        url: n.get("url").and_then(Value::as_str).unwrap_or_default().to_string(),
        state: pr::parse_state(n.get("state").and_then(Value::as_str), draft)?,
        checks: None,
        review: None,
        head_oid: n.get("headRefOid").and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string),
        merged_at: n.get("mergedAt").and_then(Value::as_str).and_then(pr::parse_iso8601).map(|t| t.floor() as i64),
    }))
}

/// The worktree's PR in a core's `pr.list` (the 30 most recently updated
/// PRs per repository; an older one reads as none).
fn from_core(list: &Value, path: &str) -> Option<PrStatus> {
    let item = list.get("prs")?.as_array()?.iter().find(|i| i.get("worktree_path").and_then(Value::as_str) == Some(path))?;
    let p = item.get("pr")?;
    Some(PrStatus { body: String::new(),
        number: p.get("number")?.as_u64()?,
        url: p.get("url").and_then(Value::as_str).unwrap_or_default().to_string(),
        state: match p.get("state")?.as_str()? {
            "open" => pr::State::Open,
            "draft" => pr::State::Draft,
            "merged" => pr::State::Merged,
            "closed" => pr::State::Closed,
            _ => return None,
        },
        checks: None,
        review: None,
        head_oid: p.get("head_oid").and_then(Value::as_str).map(str::to_string),
        merged_at: p.get("merged_at").and_then(Value::as_i64),
    })
}
