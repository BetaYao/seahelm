//! Claude Code: the hooks seahelm needs in `~/.claude/settings.json`
//! (`ClaudeHooksSetup.swift`), merged beside whatever else is there.

use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::merge::{self, as_groups};
use super::{command_word, parse_object, pretty_sorted, reconcile_file, Platform};
use crate::Map;

/// The events seahelm reports. `CwdChanged` stays, as the Swift code has it
/// (CLAUDE.md's "must not install" is stale).
pub const REQUIRED_EVENTS: [&str; 11] = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "Stop",
    "StopFailure",
    "SubagentStart",
    "SubagentStop",
    "Notification",
    "CwdChanged",
];

/// Events seahelm once installed and must now actively remove.
/// `WorktreeCreate` is not an observation hook: registering it makes Claude
/// delegate worktree creation to us and wait for a path on stdout, so every
/// `--worktree` create failed with "returned no worktree path".
pub const RETIRED_EVENTS: [&str; 1] = ["WorktreeCreate"];

/// `<hook> claude-code`: the argument declares the source, which Claude's
/// own payload keys can no longer be trusted to.
pub fn hook_command(hook_cmd: &Path, platform: Platform) -> String {
    format!("{} claude-code", command_word(hook_cmd, platform))
}

pub fn hook_entry(hook_cmd: &Path, platform: Platform) -> Value {
    serde_json::json!({"type": "command", "command": hook_command(hook_cmd, platform)})
}

/// Whether a value (an entry, or a whole event) is one seahelm installed:
/// an HTTP hook at our `/webhook`, or our `seahelm-hook` command.
pub fn is_seahelm_managed(entry: Option<&Value>) -> bool {
    entry.is_some_and(|e| {
        let s = e.to_string();
        s.contains("/webhook") || s.contains("seahelm-hook")
    })
}

/// Structural equality via canonical JSON, so key order does not count.
pub fn entries_equal(a: Option<&Value>, b: Option<&Value>) -> bool {
    a.map(merge::canonical) == b.map(merge::canonical)
}

/// The hooks settings.json should hold, and whether that differs from
/// `existing`. Split from the file I/O so the install/migrate/retire rules
/// are testable without touching a real settings.json.
pub fn reconcile(existing: &Map, hook_cmd: &Path, platform: Platform) -> (Map, bool) {
    let mut hooks = existing.clone();
    let mut changed = false;
    let entry = hook_entry(hook_cmd, platform);

    for event in REQUIRED_EVENTS {
        // A present-but-unreadable value is the user's to fix; clobbering
        // their settings is worse than not reporting one event.
        let groups = match hooks.get(event) {
            None => Vec::new(),
            Some(v) => match as_groups(v) {
                Some(g) => g,
                None => continue,
            },
        };
        if let Some(merged) = merge::merging(&groups, &entry) {
            hooks.insert(event.into(), Value::Array(merged));
            changed = true;
        }
    }

    // Dropping an event from the required list is not enough — the merge
    // only adds, so what an earlier version wrote would stay forever. Sweep
    // ours out, and only ours.
    for event in RETIRED_EVENTS {
        let Some(remaining) = hooks.get(event).and_then(as_groups).and_then(|g| merge::removing(&g)) else { continue };
        if remaining.is_empty() {
            hooks.remove(event);
        } else {
            hooks.insert(event.into(), Value::Array(remaining));
        }
        changed = true;
    }
    (hooks, changed)
}

/// settings.json's new contents, or None when it already says what it
/// should. Unparseable or missing settings start from `{}`, as the Swift did.
pub fn reconcile_settings(old: Option<&str>, hook_cmd: &Path, platform: Platform) -> Option<String> {
    let mut settings = parse_object(old).unwrap_or_default();
    let existing = settings.get("hooks").and_then(Value::as_object).cloned().unwrap_or_default();
    let (hooks, changed) = reconcile(&existing, hook_cmd, platform);
    if !changed {
        return None;
    }
    settings.insert("hooks".into(), Value::Object(hooks));
    Some(pretty_sorted(&settings))
}

pub fn settings_path(home: &Path) -> PathBuf {
    home.join(".claude").join("settings.json")
}

/// Patch `~/.claude/settings.json`; `Ok(true)` when it was written.
pub fn install(home: &Path, hook_cmd: &Path, platform: Platform) -> io::Result<bool> {
    reconcile_file(&settings_path(home), |old| reconcile_settings(old, hook_cmd, platform))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const HOOK: &str = "/Users/x/.local/bin/seahelm-hook";

    fn reconcile_unix(existing: Value) -> (Map, bool) {
        reconcile(existing.as_object().unwrap(), Path::new(HOOK), Platform::Unix)
    }

    fn seahelm_entry() -> Value {
        json!([{"hooks": [{"type": "command", "command": "/Users/x/.local/bin/seahelm-hook claude-code"}]}])
    }

    fn legacy_http_entry() -> Value {
        json!([{"hooks": [{"type": "http", "url": "http://127.0.0.1:8765/webhook"}]}])
    }

    fn user_entry() -> Value {
        json!([{"hooks": [{"type": "command", "command": "/usr/local/bin/my-own-worktree-maker"}]}])
    }

    fn commands(v: &Value) -> Vec<String> {
        v.as_array()
            .unwrap()
            .iter()
            .filter_map(|g| g.get("hooks").and_then(Value::as_array))
            .flatten()
            .filter_map(|e| e.get("command").and_then(Value::as_str).map(str::to_string))
            .collect()
    }

    // ClaudeHooksSetupTests

    #[test]
    fn test_worktree_create_is_not_installed() {
        let (hooks, _) = reconcile_unix(json!({}));
        assert!(hooks.get("WorktreeCreate").is_none());
    }

    #[test]
    fn test_observation_hooks_are_still_installed() {
        let (hooks, changed) = reconcile_unix(json!({}));
        assert!(changed);
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SubagentStop", "Notification", "CwdChanged"] {
            assert!(hooks.contains_key(event), "{event} should still be installed");
        }
        assert_eq!(commands(&hooks["Stop"]), vec![format!("{HOOK} claude-code")]);
    }

    #[test]
    fn test_existing_seahelm_worktree_create_is_removed() {
        let (hooks, changed) = reconcile_unix(json!({"WorktreeCreate": seahelm_entry()}));
        assert!(hooks.get("WorktreeCreate").is_none());
        assert!(changed);
    }

    #[test]
    fn test_legacy_http_worktree_create_is_also_removed() {
        let (hooks, changed) = reconcile_unix(json!({"WorktreeCreate": legacy_http_entry()}));
        assert!(hooks.get("WorktreeCreate").is_none());
        assert!(changed);
    }

    #[test]
    fn test_user_owned_worktree_create_is_left_alone() {
        let (hooks, _) = reconcile_unix(json!({"WorktreeCreate": user_entry()}));
        assert!(entries_equal(hooks.get("WorktreeCreate"), Some(&user_entry())));
    }

    #[test]
    fn test_unrelated_user_hooks_survive() {
        let (hooks, _) = reconcile_unix(json!({"PermissionRequest": user_entry(), "TeammateIdle": user_entry()}));
        assert!(hooks.contains_key("PermissionRequest"));
        assert!(hooks.contains_key("TeammateIdle"));
    }

    #[test]
    fn test_user_owned_observation_hook_keeps_ours_alongside() {
        let (hooks, changed) = reconcile_unix(json!({"Stop": user_entry()}));
        assert!(changed);
        let cmds = commands(&hooks["Stop"]);
        assert!(cmds.contains(&"/usr/local/bin/my-own-worktree-maker".to_string()), "user hook was disturbed: {cmds:?}");
        assert_eq!(cmds.iter().filter(|c| c.contains("seahelm-hook")).count(), 1, "ours must be present exactly once: {cmds:?}");
    }

    #[test]
    fn test_mixed_event_does_not_lose_the_user_hook() {
        let mixed = json!([
            {"hooks": [{"type": "command", "command": "/usr/local/bin/my-own-worktree-maker"}]},
            {"hooks": [{"type": "http", "url": "http://127.0.0.1:8765/webhook"}]},
        ]);
        let (hooks, _) = reconcile_unix(json!({"Stop": mixed}));
        let entries: Vec<&Value> =
            hooks["Stop"].as_array().unwrap().iter().filter_map(|g| g["hooks"].as_array()).flatten().collect();
        assert!(entries.iter().any(|e| e["command"] == "/usr/local/bin/my-own-worktree-maker"), "user hook was deleted");
        assert_eq!(entries.iter().filter(|e| e["command"].as_str().is_some_and(|c| c.contains("seahelm-hook"))).count(), 1);
        assert!(!entries.iter().any(|e| e["type"] == "http"), "legacy entry was not migrated");
    }

    #[test]
    fn test_retired_sweep_keeps_a_user_hook_in_the_same_event() {
        let mixed = json!([
            {"hooks": [{"type": "command", "command": "/usr/local/bin/my-own-worktree-maker"}]},
            {"hooks": [{"type": "command", "command": "/Users/x/.local/bin/seahelm-hook claude-code"}]},
        ]);
        let (hooks, changed) = reconcile_unix(json!({"WorktreeCreate": mixed}));
        assert!(changed);
        assert_eq!(commands(&hooks["WorktreeCreate"]), vec!["/usr/local/bin/my-own-worktree-maker"]);
    }

    #[test]
    fn test_already_correct_config_reports_no_change() {
        let (first, first_changed) = reconcile_unix(json!({}));
        assert!(first_changed);
        let (_, second_changed) = reconcile(&first, Path::new(HOOK), Platform::Unix);
        assert!(!second_changed, "reconcile should be idempotent");
    }

    #[test]
    fn test_retired_sweep_alone_counts_as_a_change() {
        let (mut settled, _) = reconcile_unix(json!({}));
        settled.insert("WorktreeCreate".into(), seahelm_entry());
        let (hooks, changed) = reconcile(&settled, Path::new(HOOK), Platform::Unix);
        assert!(changed);
        assert!(hooks.get("WorktreeCreate").is_none());
    }

    // ClaudeHooksMigrationTests (in SeahelmHookInstallerTests.swift)

    #[test]
    fn test_is_seahelm_managed() {
        let http = json!([{"hooks": [{"type": "http", "url": "http://localhost:7070/webhook"}]}]);
        let cmd = json!([{"hooks": [{"type": "command", "command": "/x/seahelm-hook"}]}]);
        let user = json!([{"hooks": [{"type": "command", "command": "/usr/bin/my-linter"}]}]);
        assert!(is_seahelm_managed(Some(&http)));
        assert!(is_seahelm_managed(Some(&cmd)));
        assert!(!is_seahelm_managed(Some(&user)));
        assert!(!is_seahelm_managed(None));
    }

    #[test]
    fn test_entries_equal_canonical() {
        let a = json!({"type": "command", "command": "/x", "extra": 1});
        let b = json!({"command": "/x", "extra": 1, "type": "command"});
        assert!(entries_equal(Some(&a), Some(&b)));
        assert!(!entries_equal(Some(&a), Some(&json!({"type": "http"}))));
    }

    #[test]
    fn settings_keep_their_other_keys_and_settle() {
        let old = r#"{"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "mine"}]}]}}"#;
        let new = reconcile_settings(Some(old), Path::new(HOOK), Platform::Unix).unwrap();
        let v: Value = serde_json::from_str(&new).unwrap();
        assert_eq!(v["model"], "opus");
        assert_eq!(commands(&v["hooks"]["Stop"]), vec!["mine".to_string(), format!("{HOOK} claude-code")]);
        assert_eq!(reconcile_settings(Some(&new), Path::new(HOOK), Platform::Unix), None);
    }

    #[test]
    fn windows_commands_need_no_shell() {
        let entry = hook_entry(Path::new(r"C:\Program Files\seahelm\seahelm-hook.exe"), Platform::Windows);
        assert_eq!(entry["command"], "\"C:\\Program Files\\seahelm\\seahelm-hook.exe\" claude-code");
    }
}
