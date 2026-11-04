//! Codex: `[features].hooks = true` in `~/.codex/config.toml`, and a
//! command hook per event in `~/.codex/hooks.json` (`CodexHooksSetup.swift`).

use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::merge::{self, as_groups};
use super::{command_word, parse_object, pretty_sorted, reconcile_file, Platform};

pub const REQUIRED_EVENTS: [&str; 5] = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"];

/// The hook command. On Unix it is wrapped so that stderr never reaches
/// Codex and a failure is never Codex's (the text matches the Swift's);
/// stdout does, because it is the core's answer — only ever a
/// SessionStart's added context. No login shell, so no profile can print
/// into it. The binary always exits 0, so on Windows it runs bare.
pub fn hook_command(hook_cmd: &Path, platform: Platform) -> String {
    match platform {
        Platform::Unix => format!("/bin/sh -c '{} codex 2>/dev/null || true'", command_word(hook_cmd, platform)),
        Platform::Windows => format!("{} codex", command_word(hook_cmd, platform)),
    }
}

pub fn hook_entry(hook_cmd: &Path, platform: Platform) -> Value {
    serde_json::json!({"type": "command", "command": hook_command(hook_cmd, platform)})
}

/// The bare key a `key = value` line assigns; None for blanks, comments and
/// table headers. Compared whole, so `hooks` is never `codex_hooks`.
fn toml_key(line: &str) -> Option<&str> {
    let t = trim_ws(line);
    if t.is_empty() || t.starts_with('#') {
        return None;
    }
    let key = trim_ws(&t[..t.find('=')?]);
    (!key.is_empty()).then_some(key)
}

fn trim_ws(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_whitespace() && c != '\n')
}

/// config.toml's new contents with `[features].hooks = true` and the
/// deprecated `codex_hooks` alias removed (it still works, but makes Codex
/// print a deprecation warning into every transcript), or None when the
/// file already says so.
pub fn reconcile_config_toml(old: Option<&str>) -> Option<String> {
    let normalized = old.unwrap_or("").replace("\r\n", "\n");
    let mut lines: Vec<String> = normalized.split('\n').map(str::to_string).collect();
    let header = lines.iter().position(|l| trim_ws(l) == "[features]");
    let mut changed = false;

    if let Some(header) = header {
        let end = (header + 1..lines.len())
            .find(|&i| {
                let t = trim_ws(&lines[i]);
                t.starts_with('[') && t.ends_with(']')
            })
            .unwrap_or(lines.len());
        // Rewrite the section whole: removing the alias and inserting the
        // key would otherwise shift each other's positions.
        let mut body: Vec<String> = lines[header + 1..end].to_vec();
        let before = body.len();
        body.retain(|l| toml_key(l) != Some("codex_hooks"));
        changed |= body.len() != before;
        match body.iter().position(|l| toml_key(l) == Some("hooks")) {
            Some(i) if trim_ws(&body[i]) == "hooks = true" => {}
            Some(i) => {
                body[i] = "hooks = true".into();
                changed = true;
            }
            None => {
                body.insert(0, "hooks = true".into());
                changed = true;
            }
        }
        if changed {
            lines.splice(header + 1..end, body);
        }
    } else {
        if lines.last().is_some_and(|l| !l.is_empty()) {
            lines.push(String::new());
        }
        lines.push("[features]".into());
        lines.push("hooks = true".into());
        changed = true;
    }
    changed.then(|| lines.join("\n") + "\n")
}

/// hooks.json's new contents, or None when every required event already
/// carries our entry. An event whose value is not a list of groups is
/// skipped, not clobbered.
pub fn reconcile_hooks_json(old: Option<&str>, hook_cmd: &Path, platform: Platform) -> Option<String> {
    let mut root = parse_object(old).unwrap_or_default();
    let mut hooks = root.get("hooks").and_then(Value::as_object).cloned().unwrap_or_default();
    let entry = hook_entry(hook_cmd, platform);
    let mut changed = false;
    for event in REQUIRED_EVENTS {
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
    if !changed {
        return None;
    }
    root.insert("hooks".into(), Value::Object(hooks));
    Some(pretty_sorted(&root))
}

pub fn codex_dir(home: &Path) -> PathBuf {
    home.join(".codex")
}

/// Patch both files; `Ok(true)` when either was written.
pub fn install(home: &Path, hook_cmd: &Path, platform: Platform) -> io::Result<bool> {
    let dir = codex_dir(home);
    std::fs::create_dir_all(&dir)?;
    let config = reconcile_file(&dir.join("config.toml"), reconcile_config_toml);
    let hooks = reconcile_file(&dir.join("hooks.json"), |old| reconcile_hooks_json(old, hook_cmd, platform));
    Ok(config? | hooks?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const HOOK: &str = "/Users/x/.local/bin/seahelm-hook";

    fn toml_file(dir: &Path, contents: Option<&str>) -> PathBuf {
        let p = dir.join("config.toml");
        if let Some(c) = contents {
            std::fs::write(&p, c).unwrap();
        }
        p
    }

    fn ensure_toml(path: &Path) -> bool {
        reconcile_file(path, reconcile_config_toml).unwrap()
    }

    fn ensure_json(path: &Path) -> bool {
        reconcile_file(path, |old| reconcile_hooks_json(old, Path::new(HOOK), Platform::Unix)).unwrap()
    }

    fn read_json(path: &Path) -> Value {
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    fn first_command(root: &Value, event: &str) -> String {
        root["hooks"][event][0]["hooks"][0]["command"].as_str().unwrap().to_string()
    }

    #[test]
    fn test_ensure_hooks_feature_enabled_appends_features_section() {
        let dir = tempfile::tempdir().unwrap();
        let url = toml_file(dir.path(), None);
        assert!(ensure_toml(&url));
        let contents = std::fs::read_to_string(&url).unwrap();
        assert!(contents.contains("[features]"));
        assert!(contents.contains("hooks = true"));
        assert!(!contents.contains("codex_hooks"));
    }

    #[test]
    fn test_deprecated_alias_is_migrated_to_canonical_key() {
        let dir = tempfile::tempdir().unwrap();
        let url = toml_file(dir.path(), Some("[features]\ncodex_hooks = true\napps = true"));
        assert!(ensure_toml(&url));
        let contents = std::fs::read_to_string(&url).unwrap();
        assert!(contents.contains("hooks = true"));
        assert!(!contents.contains("codex_hooks"), "alias left behind: {contents}");
        assert!(contents.contains("apps = true"), "unrelated feature was dropped: {contents}");
    }

    #[test]
    fn test_canonical_key_is_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let url = toml_file(dir.path(), Some("[features]\nhooks = true"));
        assert!(!ensure_toml(&url));
    }

    #[test]
    fn test_hook_command_passes_only_stdout() {
        let dir = tempfile::tempdir().unwrap();
        let url = dir.path().join("hooks.json");
        assert!(ensure_json(&url));
        let cmd = first_command(&read_json(&url), "Stop");
        // stdout is the bridge's answer (a SessionStart's added context), so
        // it reaches Codex; stderr never does, and no login shell runs to
        // print a profile's chatter into it.
        assert!(cmd.contains("2>/dev/null") && !cmd.contains(">/dev/null 2>&1"), "{cmd}");
        assert!(!cmd.contains("-lc"), "{cmd}");
        assert!(cmd.contains(HOOK), "must invoke the bridge by absolute path: {cmd}");
    }

    #[test]
    fn test_stale_seahelm_owned_command_is_upgraded() {
        let dir = tempfile::tempdir().unwrap();
        let url = dir.path().join("hooks.json");
        let stale = format!("/bin/sh -lc '{HOOK} >/dev/null 2>&1 || true'");
        std::fs::write(&url, json!({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": stale}]}]}}).to_string()).unwrap();
        assert!(ensure_json(&url));
        let command = first_command(&read_json(&url), "Stop");
        assert_ne!(command, stale, "stale seahelm hook was left in place");
        assert!(command.contains("codex 2>/dev/null"));
    }

    #[test]
    fn test_ensure_hooks_feature_enabled_replaces_false() {
        let dir = tempfile::tempdir().unwrap();
        let url = toml_file(dir.path(), Some("[features]\nhooks = false\napps = true"));
        assert!(ensure_toml(&url));
        let contents = std::fs::read_to_string(&url).unwrap();
        assert!(contents.contains("hooks = true"));
        assert!(!contents.contains("hooks = false"));
        assert!(contents.contains("apps = true"));
    }

    #[test]
    fn test_ensure_hooks_json_adds_required_events() {
        let dir = tempfile::tempdir().unwrap();
        let url = dir.path().join("hooks.json");
        assert!(ensure_json(&url));
        let root = read_json(&url);
        for event in REQUIRED_EVENTS {
            assert!(root["hooks"].get(event).is_some(), "Missing hook config for {event}");
        }
    }

    #[test]
    fn test_ensure_hooks_json_preserves_existing_event() {
        let dir = tempfile::tempdir().unwrap();
        let url = dir.path().join("hooks.json");
        std::fs::write(&url, json!({"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "existing-command"}]}]}}).to_string())
            .unwrap();
        assert!(ensure_json(&url));
        assert_eq!(first_command(&read_json(&url), "SessionStart"), "existing-command");
    }

    #[test]
    fn test_foreign_hook_gets_ours_appended_rather_than_skipped() {
        let dir = tempfile::tempdir().unwrap();
        let url = dir.path().join("hooks.json");
        std::fs::write(&url, json!({"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "other-tool-hook"}]}]}}).to_string())
            .unwrap();
        assert!(ensure_json(&url));
        let root = read_json(&url);
        let commands: Vec<&str> =
            root["hooks"]["SessionStart"].as_array().unwrap().iter().filter_map(|g| g["hooks"][0]["command"].as_str()).collect();
        assert!(commands.contains(&"other-tool-hook"), "foreign hook was disturbed: {commands:?}");
        assert_eq!(commands.iter().filter(|c| c.contains(HOOK)).count(), 1, "ours must be present exactly once: {commands:?}");
    }

    #[test]
    fn test_second_run_is_an_idempotent_no_op() {
        let dir = tempfile::tempdir().unwrap();
        let url = dir.path().join("hooks.json");
        assert!(ensure_json(&url));
        let first = std::fs::read(&url).unwrap();
        assert!(!ensure_json(&url));
        assert_eq!(first, std::fs::read(&url).unwrap());
    }

    #[test]
    fn toml_keeps_the_rest_of_the_file() {
        // Byte for byte what the Swift wrote, including the blank line it
        // leaves before an appended section.
        assert_eq!(reconcile_config_toml(Some("model = \"o3\"\n")).as_deref(), Some("model = \"o3\"\n\n[features]\nhooks = true\n"));
        assert_eq!(reconcile_config_toml(None).as_deref(), Some("\n[features]\nhooks = true\n"));
        assert_eq!(
            reconcile_config_toml(Some("[features]\napps = true\n[other]\nx = 1")).as_deref(),
            Some("[features]\nhooks = true\napps = true\n[other]\nx = 1\n")
        );
    }

    #[test]
    fn windows_runs_the_binary_without_a_shell() {
        let cmd = hook_command(Path::new(r"C:\seahelm\seahelm-hook.exe"), Platform::Windows);
        assert_eq!(cmd, r"C:\seahelm\seahelm-hook.exe codex");
        assert!(!cmd.contains("/bin/sh"));
    }
}
