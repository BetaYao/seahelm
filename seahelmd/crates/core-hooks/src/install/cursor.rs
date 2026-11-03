//! Cursor: `~/.cursor/hooks.json` (`CursorHooksSetup.swift`). Each event is
//! a flat list of entries, not of groups, so it has its own merge: a
//! user's entries stay, ours is appended once, and an older entry of ours
//! (any command containing `seahelm-hook`) is upgraded in place.

use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{command_word, parse_object, pretty_sorted, reconcile_file, Platform};
use crate::Map;

/// Cursor's camelCase events. `afterAgentResponse` is there because
/// Cursor's stop payload has no `last_assistant_message`: it is where the
/// `::seahelm-suggest::` line is harvested.
pub const REQUIRED_EVENTS: [&str; 6] = ["sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "afterAgentResponse", "stop"];

/// `<hook> cursor`: Cursor's payload carries no key that identifies it.
pub fn hook_command(hook_cmd: &Path, platform: Platform) -> String {
    format!("{} cursor", command_word(hook_cmd, platform))
}

fn required_entry(hook_cmd: &Path, platform: Platform) -> Map {
    let mut m = Map::new();
    m.insert("command".into(), hook_command(hook_cmd, platform).into());
    m
}

/// An entry seahelm installed, safe to upgrade.
pub fn is_seahelm_managed(entry: &Map) -> bool {
    entry.get("command").and_then(Value::as_str).is_some_and(|c| c.contains("seahelm-hook"))
}

/// hooks.json's new contents, or None when it is already as required.
pub fn reconcile_hooks_json(old: Option<&str>, hook_cmd: &Path, platform: Platform) -> Option<String> {
    let mut root = parse_object(old).unwrap_or_default();
    let mut hooks = root.get("hooks").and_then(Value::as_object).cloned().unwrap_or_default();
    let mut changed = false;
    if root.get("version").and_then(Value::as_i64) != Some(1) {
        root.insert("version".into(), 1.into());
        changed = true;
    }
    let required = required_entry(hook_cmd, platform);
    for event in REQUIRED_EVENTS {
        // As the Swift read it (`as? [[String: Any]] ?? []`): any other
        // shape is replaced.
        let mut list: Vec<Map> = hooks
            .get(event)
            .and_then(Value::as_array)
            .filter(|a| a.iter().all(Value::is_object))
            .map(|a| a.iter().filter_map(|e| e.as_object().cloned()).collect())
            .unwrap_or_default();
        match list.iter().position(is_seahelm_managed) {
            Some(i) if list[i] == required => {}
            Some(i) => {
                list[i] = required.clone();
                changed = true;
            }
            None => {
                list.push(required.clone());
                changed = true;
            }
        }
        hooks.insert(event.into(), Value::Array(list.into_iter().map(Value::Object).collect()));
    }
    if !changed {
        return None;
    }
    root.insert("hooks".into(), Value::Object(hooks));
    Some(pretty_sorted(&root))
}

pub fn hooks_path(home: &Path) -> PathBuf {
    home.join(".cursor").join("hooks.json")
}

pub fn install(home: &Path, hook_cmd: &Path, platform: Platform) -> io::Result<bool> {
    install_at(&hooks_path(home), hook_cmd, platform)
}

/// [`install`] against an explicit hooks.json.
pub fn install_at(path: &Path, hook_cmd: &Path, platform: Platform) -> io::Result<bool> {
    reconcile_file(path, |old| reconcile_hooks_json(old, hook_cmd, platform))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const HOOK: &str = "/Users/x/.local/bin/seahelm-hook";

    fn ensure(path: &Path) -> bool {
        install_at(path, Path::new(HOOK), Platform::Unix).unwrap()
    }

    fn read(path: &Path) -> Value {
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    #[test]
    fn test_ensure_hooks_json_adds_required_events_and_version() {
        let dir = tempfile::tempdir().unwrap();
        let url = dir.path().join("hooks.json");
        assert!(ensure(&url));
        let root = read(&url);
        assert_eq!(root["version"], 1);
        for event in REQUIRED_EVENTS {
            assert_eq!(root["hooks"][event][0]["command"], format!("{HOOK} cursor"), "missing {event}");
        }
        assert!(root["hooks"]["stop"][0].get("loop_limit").is_none());
    }

    #[test]
    fn test_preserves_user_owned_hooks_and_appends_seahelm() {
        let dir = tempfile::tempdir().unwrap();
        let url = dir.path().join("hooks.json");
        std::fs::write(&url, json!({"version": 1, "hooks": {"stop": [{"command": "./hooks/my-audit.sh"}]}}).to_string()).unwrap();
        assert!(ensure(&url));
        let stop = read(&url)["hooks"]["stop"].clone();
        assert_eq!(stop.as_array().unwrap().len(), 2);
        assert_eq!(stop[0]["command"], "./hooks/my-audit.sh");
        assert!(stop[1]["command"].as_str().unwrap().contains("seahelm-hook"));
    }

    #[test]
    fn test_upgrades_stale_seahelm_owned_command() {
        let dir = tempfile::tempdir().unwrap();
        let url = dir.path().join("hooks.json");
        std::fs::write(&url, json!({"version": 1, "hooks": {"stop": [{"command": "/old/path/seahelm-hook"}]}}).to_string()).unwrap();
        assert!(ensure(&url));
        let stop = read(&url)["hooks"]["stop"].clone();
        assert_eq!(stop.as_array().unwrap().len(), 1);
        assert_eq!(stop[0]["command"], format!("{HOOK} cursor"));
    }

    #[test]
    fn a_settled_file_is_not_rewritten() {
        let dir = tempfile::tempdir().unwrap();
        let url = dir.path().join("hooks.json");
        assert!(ensure(&url));
        assert!(!ensure(&url));
    }
}
