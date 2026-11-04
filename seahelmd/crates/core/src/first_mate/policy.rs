//! What a call from First Mate may be (`AutopilotPolicy.swift`). The core,
//! not the model, enforces it: every call First Mate's CLI makes names it
//! in `_meta.caller` and is classified before anything runs.

use serde_json::Value;

use super::rules::Action;

/// First Mate's seahelmd session; its CLI exports it as `SEAHELM_PANE_ID`.
pub const SESSION: &str = "seahelm-first-mate";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Class {
    /// Reads and waits: always allowed.
    Open,
    /// Under the autonomy policy.
    Gated(Action),
    /// Not First Mate's to do (closing panes, rearranging layouts…).
    Forbidden,
}

pub fn classify(method: &str) -> Class {
    match method {
        // A card, not an action: nothing runs until the user picks.
        "autopilot.propose" | "core.ping" | "ping" | "pane.list" | "session.snapshot" | "pane.read" | "pane.explain"
        | "agent.explain" | "worktree.list" | "fleet.status" | "pr.list" | "pane.wait_agent_status" | "wait.agent_status"
        | "usage.summary" | "cards.list" | "autopilot.state" | "message.snapshot" | "message.history" => Class::Open,
        "pane.run" | "pane.send_text" | "pane.send_keys" => Class::Gated(Action::MessagePane),
        "worktree.create" => Class::Gated(Action::StartAgent),
        "worktree.delete" => Class::Gated(Action::DeleteWorktree),
        _ => Class::Forbidden,
    }
}

pub fn is_first_mate(params: &Value) -> bool {
    caller(params).as_deref() == Some(SESSION)
}

pub fn caller(params: &Value) -> Option<String> {
    params.pointer("/_meta/caller").and_then(Value::as_str).filter(|c| !c.is_empty()).map(str::to_string)
}

/// The call as the user's, for running once they said yes: without
/// `_meta`, so it is not gated a second time.
pub fn as_user(params: &Value) -> Value {
    let mut p = params.clone();
    if let Some(o) = p.as_object_mut() {
        o.remove("_meta");
    }
    p
}

/// One line for a card or the audit log. `facts` is what a delete would
/// throw away, as measured.
pub fn describe(method: &str, params: &Value, facts: Option<&str>) -> String {
    let s = |k: &str| params.get(k).and_then(Value::as_str).unwrap_or_default();
    let base = |p: &str| std::path::Path::new(p).file_name().and_then(|n| n.to_str()).unwrap_or(p).to_string();
    let one_line = |t: &str| t.replace('\n', " ").chars().take(160).collect::<String>();
    match method {
        "worktree.create" => format!("Start an agent in {}: {}", base(s("repo_path")), one_line(s("prompt"))),
        "worktree.delete" => format!("Delete worktree {}{}", base(s("worktree_path")), facts.map(|f| format!(" — {f}")).unwrap_or_default()),
        _ => {
            let pane = params.get("pane_id").and_then(Value::as_str).unwrap_or("?");
            let text = [s("command"), s("text")].into_iter().find(|t| !t.is_empty()).map(str::to_string).unwrap_or_else(|| {
                params.get("keys").and_then(Value::as_array).map(|k| k.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" ")).unwrap_or_default()
            });
            format!("Tell {pane}: {}", one_line(&text))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn classes() {
        assert_eq!(classify("pane.list"), Class::Open);
        assert_eq!(classify("pane.run"), Class::Gated(Action::MessagePane));
        assert_eq!(classify("worktree.delete"), Class::Gated(Action::DeleteWorktree));
        assert_eq!(classify("pane.close"), Class::Forbidden);
        assert_eq!(classify("cards.answer"), Class::Forbidden);
    }

    #[test]
    fn callers_and_descriptions() {
        let p = json!({"_meta": {"caller": SESSION}, "pane_id": "#3", "command": "fix it\nnow"});
        assert!(is_first_mate(&p));
        assert!(!is_first_mate(&as_user(&p)));
        assert_eq!(describe("pane.run", &p, None), "Tell #3: fix it now");
        let d = json!({"worktree_path": "/w/feat-x"});
        assert_eq!(describe("worktree.delete", &d, Some("nothing uncommitted")), "Delete worktree feat-x — nothing uncommitted");
    }
}
