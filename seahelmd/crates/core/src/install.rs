//! `seahelm-core install-hooks`: wire the agents' hooks to `seahelm-core
//! hook`, so their lifecycle events reach the core with no macOS app in
//! between (Linux, Windows, or a Mac without the app).
//!
//! The same files and events the app's installers manage (the event lists
//! and Codex's `config.toml` rule come from their port,
//! `seahelm_core_hooks::install`), and the same merge rules
//! (`HookEventMerge.swift`). The port's own merge is not used because it
//! takes any `seahelm-hook` entry for its own and would rewrite the app's.
//! So: other people's hooks are never
//! rewritten, reordered or removed; our entry is migrated in place when the
//! exe moved; duplicates of ours collapse to the first. One rule of its own:
//! an event that already runs the app's bridge (`seahelm-hook`) is left
//! alone — that bridge reaches the core itself, and a second hook would
//! deliver every event twice.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use seahelm_core_hooks::install::{claude, codex};
use serde_json::{json, Map, Value};

/// Claude Code's events and Codex's: the ported installers' lists
/// (`ClaudeHooksSetup` / `CodexHooksSetup.requiredEvents`).
pub const CLAUDE_EVENTS: &[&str] = &claude::REQUIRED_EVENTS;
pub const CODEX_EVENTS: &[&str] = &codex::REQUIRED_EVENTS;

/// What one file came to.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Unchanged,
    Written,
    /// There and not JSON (or not the shape expected): left as it was.
    Unreadable(String),
}

pub fn run(_args: &[String]) -> Result<()> {
    let exe = std::env::current_exe().context("where is seahelm-core")?;
    let home = home();
    let lines = install(&home, &exe);
    for line in lines {
        println!("{line}");
    }
    Ok(())
}

fn home() -> PathBuf {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_default()
}

/// Install into `home` for `exe`; one line per file saying what happened.
pub fn install(home: &Path, exe: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let claude = home.join(".claude").join("settings.json");
    out.push(report("Claude Code", &claude, merge_file(&claude, CLAUDE_EVENTS, &command(exe, "claude-code"))));
    let codex_dir = home.join(".codex");
    let hooks = codex_dir.join("hooks.json");
    out.push(report("Codex hooks", &hooks, merge_file(&hooks, CODEX_EVENTS, &command(exe, "codex"))));
    let config = codex_dir.join("config.toml");
    out.push(report("Codex [features].hooks", &config, enable_codex_hooks(&config)));
    out
}

fn report(what: &str, path: &Path, outcome: Result<Outcome>) -> String {
    match outcome {
        Ok(Outcome::Unchanged) => format!("{what}: already set ({})", path.display()),
        Ok(Outcome::Written) => format!("{what}: updated {}", path.display()),
        Ok(Outcome::Unreadable(why)) => format!("{what}: left untouched, {why} ({})", path.display()),
        Err(e) => format!("{what}: failed: {e:#} ({})", path.display()),
    }
}

/// The hook command: the exe, quoted for the shell the agent runs it
/// through, then `hook <source>`.
pub fn command(exe: &Path, source: &str) -> String {
    format!("{} hook {source}", quote(&exe.to_string_lossy()))
}

/// A path as one shell word. On Windows always in double quotes (a path
/// cannot hold one, and both cmd and Git Bash take them). Elsewhere bare
/// when it has nothing a shell would read, else single-quoted.
pub fn quote(path: &str) -> String {
    if cfg!(windows) {
        return format!("\"{path}\"");
    }
    let safe = !path.is_empty() && path.chars().all(|c| c.is_ascii_alphanumeric() || "/._-+:@%,=".contains(c));
    if safe {
        path.to_string()
    } else {
        format!("'{}'", path.replace('\'', r"'\''"))
    }
}

fn is_app_bridge(entry: &Value) -> bool {
    let s = entry.to_string();
    s.contains("seahelm-hook") || s.contains("/webhook")
}

fn is_ours(entry: &Value) -> bool {
    entry.get("command").and_then(Value::as_str).is_some_and(|c| c.contains("seahelm-core") && c.contains(" hook "))
}

/// Merge our entry into one event's groups; None when it already says what
/// it should (or the event is the app bridge's), so the file stays as it is.
pub fn merge_event(groups: &[Value], entry: &Value) -> Option<Vec<Value>> {
    let entries = |g: &Value| g.get("hooks").and_then(Value::as_array).cloned();
    if groups.iter().filter_map(entries).flatten().any(|e| is_app_bridge(&e)) {
        return None;
    }
    let mut merged = Vec::new();
    let mut changed = false;
    let mut installed = false;
    for group in groups {
        let Some(list) = entries(group).filter(|l| !l.is_empty()) else {
            merged.push(group.clone());
            continue;
        };
        let mut kept = Vec::new();
        for existing in list {
            if !is_ours(&existing) {
                kept.push(existing);
                continue;
            }
            if installed {
                changed = true;
                continue;
            }
            installed = true;
            if &existing == entry {
                kept.push(existing);
            } else {
                kept.push(entry.clone());
                changed = true;
            }
        }
        if kept.is_empty() {
            changed = true;
            continue;
        }
        let mut group = group.clone();
        group["hooks"] = Value::Array(kept);
        merged.push(group);
    }
    if !installed {
        merged.push(json!({"hooks": [entry]}));
        changed = true;
    }
    changed.then_some(merged)
}

/// One agent's settings file: every event in `events` made to run
/// `command`, everything else as it was.
pub fn merge_file(path: &Path, events: &[&str], command: &str) -> Result<Outcome> {
    let mut root = match std::fs::read_to_string(path) {
        Ok(text) if text.trim().is_empty() => Value::Object(Map::new()),
        Ok(text) => match serde_json::from_str::<Value>(&text) {
            Ok(v @ Value::Object(_)) => v,
            Ok(_) => return Ok(Outcome::Unreadable("not a JSON object".into())),
            Err(e) => return Ok(Outcome::Unreadable(format!("not JSON: {e}"))),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Value::Object(Map::new()),
        Err(e) => return Err(e).with_context(|| format!("read {}", path.display())),
    };
    let hooks = root.as_object_mut().unwrap().entry("hooks").or_insert_with(|| Value::Object(Map::new()));
    let Some(hooks) = hooks.as_object_mut() else {
        return Ok(Outcome::Unreadable("`hooks` is not an object".into()));
    };
    let entry = json!({"type": "command", "command": command});
    let mut changed = false;
    for event in events {
        let groups = match hooks.get(*event) {
            None => Vec::new(),
            Some(Value::Array(g)) => g.clone(),
            // Someone else's shape: theirs to fix, not ours to clobber.
            Some(_) => continue,
        };
        if let Some(merged) = merge_event(&groups, &entry) {
            hooks.insert(event.to_string(), Value::Array(merged));
            changed = true;
        }
    }
    if !changed {
        return Ok(Outcome::Unchanged);
    }
    let mut text = serde_json::to_string_pretty(&root)?;
    text.push('\n');
    write_atomic(path, &text)?;
    Ok(Outcome::Written)
}

/// `[features] hooks = true` in Codex's config.toml, without the
/// deprecated `codex_hooks` alias (`codex::reconcile_config_toml`).
pub fn enable_codex_hooks(path: &Path) -> Result<Outcome> {
    let old = match std::fs::read_to_string(path) {
        Ok(t) => Some(t),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(e).with_context(|| format!("read {}", path.display())),
    };
    match codex::reconcile_config_toml(old.as_deref()) {
        Some(new) => {
            write_atomic(path, &new)?;
            Ok(Outcome::Written)
        }
        None => Ok(Outcome::Unchanged),
    }
}

fn write_atomic(path: &Path, text: &str) -> Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    let tmp = path.with_extension("seahelm-core.tmp");
    std::fs::write(&tmp, text).with_context(|| format!("write {}", tmp.display()))?;
    std::fs::rename(&tmp, path).with_context(|| format!("replace {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXE: &str = "/opt/seahelm/bin/seahelm-core";

    fn read(p: &Path) -> Value {
        serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
    }

    fn commands(v: &Value, event: &str) -> Vec<String> {
        v["hooks"][event]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|g| g["hooks"].as_array().unwrap().iter().map(|e| e["command"].as_str().unwrap_or("").to_string()))
            .collect()
    }

    #[test]
    fn a_fresh_home_gets_every_event_and_the_codex_feature() {
        let home = tempfile::tempdir().unwrap();
        install(home.path(), Path::new(EXE));
        let claude = read(&home.path().join(".claude/settings.json"));
        for e in CLAUDE_EVENTS {
            assert_eq!(commands(&claude, e), [command(Path::new(EXE), "claude-code")], "{e}");
        }
        let codex = read(&home.path().join(".codex/hooks.json"));
        for e in CODEX_EVENTS {
            assert_eq!(commands(&codex, e), [command(Path::new(EXE), "codex")], "{e}");
        }
        let toml = std::fs::read_to_string(home.path().join(".codex/config.toml")).unwrap();
        assert!(toml.contains("[features]\nhooks = true\n"), "{toml:?}");
    }

    #[test]
    fn the_users_hooks_and_settings_stay_in_place() {
        let home = tempfile::tempdir().unwrap();
        let path = home.path().join(".claude/settings.json");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            &path,
            r#"{"model":"opus","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"say done"}]}],"Custom":[1]}}"#,
        )
        .unwrap();
        assert_eq!(merge_file(&path, CLAUDE_EVENTS, &command(Path::new(EXE), "claude-code")).unwrap(), Outcome::Written);
        let v = read(&path);
        assert_eq!(v["model"], "opus");
        assert_eq!(v["hooks"]["Custom"], json!([1]));
        assert_eq!(commands(&v, "Stop"), ["say done".to_string(), command(Path::new(EXE), "claude-code")]);
        assert_eq!(v["hooks"]["Stop"][0]["matcher"], "");
        let keys: Vec<&String> = v.as_object().unwrap().keys().collect();
        assert_eq!(keys, ["model", "hooks"], "key order kept");
    }

    #[test]
    fn an_event_with_the_app_bridge_is_left_alone() {
        let home = tempfile::tempdir().unwrap();
        let path = home.path().join("settings.json");
        let app = r#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/Users/me/.local/bin/seahelm-hook claude-code"}]}]}}"#;
        std::fs::write(&path, app).unwrap();
        merge_file(&path, &["Stop", "PreToolUse"], &command(Path::new(EXE), "claude-code")).unwrap();
        let v = read(&path);
        assert_eq!(commands(&v, "Stop"), ["/Users/me/.local/bin/seahelm-hook claude-code"]);
        assert_eq!(commands(&v, "PreToolUse"), [command(Path::new(EXE), "claude-code")]);
    }

    #[test]
    fn a_moved_exe_is_updated_in_place_and_duplicates_go() {
        let home = tempfile::tempdir().unwrap();
        let path = home.path().join("hooks.json");
        let old = r#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/old/seahelm-core hook codex"},{"type":"command","command":"keep me"}]},{"hooks":[{"type":"command","command":"/older/seahelm-core hook codex"}]}]}}"#;
        std::fs::write(&path, old).unwrap();
        merge_file(&path, &["Stop"], &command(Path::new(EXE), "codex")).unwrap();
        let v = read(&path);
        assert_eq!(commands(&v, "Stop"), [command(Path::new(EXE), "codex"), "keep me".to_string()]);
        assert_eq!(v["hooks"]["Stop"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn a_second_run_changes_nothing() {
        let home = tempfile::tempdir().unwrap();
        install(home.path(), Path::new(EXE));
        let before = std::fs::read_to_string(home.path().join(".claude/settings.json")).unwrap();
        let lines = install(home.path(), Path::new(EXE));
        assert!(lines.iter().all(|l| l.contains("already set")), "{lines:?}");
        assert_eq!(std::fs::read_to_string(home.path().join(".claude/settings.json")).unwrap(), before);
    }

    #[test]
    fn an_unreadable_file_is_not_touched() {
        let home = tempfile::tempdir().unwrap();
        let path = home.path().join("settings.json");
        std::fs::write(&path, "{ not json").unwrap();
        assert!(matches!(merge_file(&path, CLAUDE_EVENTS, "x hook y").unwrap(), Outcome::Unreadable(_)));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{ not json");
    }

    #[test]
    fn codex_config_keeps_its_other_settings_and_drops_the_alias() {
        let home = tempfile::tempdir().unwrap();
        let path = home.path().join("config.toml");
        std::fs::write(&path, "model = \"o3\"\n\n[features]\ncodex_hooks = true\nother = 1\n\n[tui]\nx = 2\n").unwrap();
        assert_eq!(enable_codex_hooks(&path).unwrap(), Outcome::Written);
        let toml = std::fs::read_to_string(&path).unwrap();
        assert!(toml.starts_with("model = \"o3\"\n"), "{toml:?}");
        assert!(toml.contains("[features]\nhooks = true\nother = 1\n"), "{toml:?}");
        assert!(toml.contains("[tui]\nx = 2"), "{toml:?}");
        assert!(!toml.contains("codex_hooks"), "{toml:?}");
        assert_eq!(enable_codex_hooks(&path).unwrap(), Outcome::Unchanged);
    }

    #[test]
    fn paths_are_quoted_when_a_shell_would_read_them() {
        if cfg!(windows) {
            assert_eq!(quote(r"C:\Program Files\seahelm-core.exe"), r#""C:\Program Files\seahelm-core.exe""#);
        } else {
            assert_eq!(quote("/opt/bin/seahelm-core"), "/opt/bin/seahelm-core");
            assert_eq!(quote("/Users/a b/seahelm-core"), "'/Users/a b/seahelm-core'");
            assert_eq!(quote("/x/it's"), r"'/x/it'\''s'");
        }
    }
}
