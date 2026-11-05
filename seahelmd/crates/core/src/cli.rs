//! `seahelm-core cli …`: the `seahelm` commands First Mate's instructions
//! use, answered by the core, so the same words work where there is no app.
//! First Mate's directory has a `seahelm` shim onto this (`first_mate::pane`).
//!
//! Every call carries `_meta.caller` = `$SEAHELM_PANE_ID`: the core gates
//! First Mate's calls by it.

use std::time::Duration;

use serde_json::{json, Value};

use crate::rpc;

const USAGE: &str = "usage: seahelm <command>
  pane list
  pane read <pane> [--lines N]
  pane run <pane> <text…>
  pane send <pane> <text…>
  pane keys <pane> <key…>
  pane wait <pane> [--status done|idle|running|waiting] [--timeout SECS]
  worktree create --repo <path> --task <text> [--agent claudeCode|codex]
  habit propose --json '<habit>'
  worktree delete <worktree-path> [--habit <id>]
  propose --json '<{\"summary\": …, \"options\": [{\"label\", \"action\", \"params\"}]}>'
  cards";

/// Exit status: 0 done, 1 refused or failed, 2 usage.
pub fn run(args: &[String]) -> i32 {
    match go(args) {
        Ok(()) => 0,
        Err(Fail::Usage) => {
            eprintln!("{USAGE}");
            2
        }
        Err(Fail::Call(e)) => {
            eprintln!("seahelm: {e}");
            1
        }
    }
}

enum Fail {
    Usage,
    Call(String),
}

/// `--name value` pairs out of `args`, and what is left.
fn flags(args: &[String]) -> (Vec<(String, String)>, Vec<String>) {
    let (mut named, mut rest) = (Vec::new(), Vec::new());
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.strip_prefix("--") {
            Some(name) if !name.is_empty() => named.push((name.to_string(), it.next().cloned().unwrap_or_default())),
            _ => rest.push(a.clone()),
        }
    }
    (named, rest)
}

fn flag<'a>(named: &'a [(String, String)], name: &str) -> Option<&'a str> {
    named.iter().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
}

fn call(method: &str, mut params: Value, timeout: Duration) -> Result<Value, Fail> {
    if let Ok(caller) = std::env::var("SEAHELM_PANE_ID") {
        if !caller.is_empty() {
            params["_meta"] = json!({"caller": caller});
        }
    }
    rpc::call_with_timeout(&rpc::core_socket(), method, params, timeout).map_err(|e| Fail::Call(e.to_string()))
}

fn print(v: &Value) {
    println!("{}", serde_json::to_string_pretty(v).unwrap_or_default());
}

fn go(args: &[String]) -> Result<(), Fail> {
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    let short = Duration::from_secs(15);
    match words.as_slice() {
        ["pane", "list", ..] => {
            let v = call("pane.list", json!({}), short)?;
            println!("PANE\tSTATUS\tAGENT\tWORKTREE");
            for p in v.get("panes").and_then(Value::as_array).into_iter().flatten() {
                let s = |k: &str| p.get(k).and_then(Value::as_str).unwrap_or("").to_string();
                println!("{}\t{}\t{}\t{}", s("pane_id"), s("status"), s("agent_type"), s("worktree_path"));
            }
            Ok(())
        }
        ["pane", "read", pane, rest @ ..] => {
            let (named, _) = flags(&rest.iter().map(|s| s.to_string()).collect::<Vec<_>>());
            let lines = flag(&named, "lines").and_then(|n| n.parse::<u64>().ok()).unwrap_or(200);
            let v = call("pane.read", json!({"pane_id": pane, "lines": lines}), short)?;
            println!("{}", v.get("text").and_then(Value::as_str).unwrap_or_default());
            Ok(())
        }
        ["pane", "run", pane, text @ ..] if !text.is_empty() => {
            print(&call("pane.run", json!({"pane_id": pane, "command": text.join(" ")}), short)?);
            Ok(())
        }
        ["pane", "send", pane, text @ ..] if !text.is_empty() => {
            print(&call("pane.send_text", json!({"pane_id": pane, "text": text.join(" ")}), short)?);
            Ok(())
        }
        ["pane", "keys", pane, keys @ ..] if !keys.is_empty() => {
            print(&call("pane.send_keys", json!({"pane_id": pane, "keys": keys}), short)?);
            Ok(())
        }
        ["pane", "wait", pane, rest @ ..] => {
            let (named, _) = flags(&rest.iter().map(|s| s.to_string()).collect::<Vec<_>>());
            let timeout = flag(&named, "timeout").and_then(|t| t.parse::<f64>().ok()).unwrap_or(600.0);
            let status = flag(&named, "status").unwrap_or("done");
            let v = call(
                "pane.wait_agent_status",
                json!({"pane_id": pane, "status": status, "timeout": timeout}),
                Duration::from_secs_f64(timeout + 10.0),
            )?;
            print(&v);
            Ok(())
        }
        ["worktree", "create", rest @ ..] => {
            let (named, _) = flags(&rest.iter().map(|s| s.to_string()).collect::<Vec<_>>());
            let (Some(repo), Some(task)) = (flag(&named, "repo"), flag(&named, "task")) else { return Err(Fail::Usage) };
            let mut p = json!({"repo_path": repo, "prompt": task});
            if let Some(a) = flag(&named, "agent") {
                p["agent_type"] = json!(a);
            }
            print(&call("worktree.create", p, Duration::from_secs(120))?);
            Ok(())
        }
        ["worktree", "delete", path, rest @ ..] => {
            let (named, _) = flags(&rest.iter().map(|s| s.to_string()).collect::<Vec<_>>());
            let mut params = json!({"worktree_path": path});
            if let Some(habit) = flag(&named, "habit") { params["habit"] = json!(habit); }
            print(&call("worktree.delete", params, Duration::from_secs(120))?);
            Ok(())
        }
        ["habit", "list"] => { print(&call("habits.list", json!({}), short)?); Ok(()) }
        ["habit", "propose", rest @ ..] => {
            let (named, _) = flags(&rest.iter().map(|s| s.to_string()).collect::<Vec<_>>());
            let habit: Value = serde_json::from_str(flag(&named, "json").ok_or(Fail::Usage)?).map_err(|e| Fail::Call(format!("--json: {e}")))?;
            print(&call("habits.propose", json!({"habit":habit}), short)?);
            Ok(())
        }
        ["propose", rest @ ..] => {
            let (named, _) = flags(&rest.iter().map(|s| s.to_string()).collect::<Vec<_>>());
            let doc: Value = serde_json::from_str(flag(&named, "json").ok_or(Fail::Usage)?).map_err(|e| Fail::Call(format!("--json: {e}")))?;
            print(&call("autopilot.propose", doc, short)?);
            Ok(())
        }
        ["cards", ..] => {
            print(&call("cards.list", json!({}), short)?);
            Ok(())
        }
        _ => Err(Fail::Usage),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flags_and_words() {
        let args: Vec<String> = ["--repo", "/r", "--task", "fix it", "extra"].iter().map(|s| s.to_string()).collect();
        let (named, rest) = flags(&args);
        assert_eq!(flag(&named, "repo"), Some("/r"));
        assert_eq!(flag(&named, "task"), Some("fix it"));
        assert_eq!(rest, vec!["extra".to_string()]);
    }
}
