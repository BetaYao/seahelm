//! `~/.config/seahelm/config.json`, the settings the macOS app writes and
//! seahelm-core reads (it re-reads them as it goes, so a change applies
//! without a restart). This client reads and writes only the keys its
//! Settings page offers; every other key is kept exactly as found, since
//! the app keeps much more in the same file.

use serde_json::{Map, Value};

fn path() -> std::path::PathBuf {
    crate::platform::config_dir().join("config.json")
}

/// The file as an object; empty when missing or not an object.
pub fn read() -> Map<String, Value> {
    std::fs::read_to_string(path())
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default()
}

pub fn flag(key: &str) -> bool {
    read().get(key).and_then(Value::as_bool).unwrap_or(false)
}

/// Set one key, keeping the rest. Refuses to touch a file that is there
/// but does not parse, rather than replace it with one key.
pub fn set(key: &str, value: Value) -> Result<(), String> {
    let p = path();
    let current = std::fs::read_to_string(&p).ok();
    let text = merged(current.as_deref(), key, value).map_err(|e| format!("{}: {e}", p.display()))?;
    std::fs::create_dir_all(crate::platform::config_dir()).map_err(|e| e.to_string())?;
    // Written beside and moved over, so a reader never sees half a file.
    let tmp = p.with_extension("json.gpui-tmp");
    std::fs::write(&tmp, text).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &p).map_err(|e| e.to_string())
}

/// The file's text with `key` set: everything else as it was.
fn merged(current: Option<&str>, key: &str, value: Value) -> Result<String, String> {
    let mut obj = match current {
        Some(text) if !text.trim().is_empty() => match serde_json::from_str::<Value>(text) {
            Ok(Value::Object(o)) => o,
            _ => return Err("not a JSON object; not changed".into()),
        },
        _ => Map::new(),
    };
    obj.insert(key.to_string(), value);
    serde_json::to_string_pretty(&Value::Object(obj)).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::merged;
    use serde_json::{json, Value};

    #[test]
    fn setting_one_key_keeps_the_rest() {
        let before = r#"{"theme_mode": "dark", "telegram": {"bot_token": "x"}, "autopilot_enabled": false}"#;
        let after: Value = serde_json::from_str(&merged(Some(before), "autopilot_enabled", json!(true)).unwrap()).unwrap();
        assert_eq!(after["autopilot_enabled"], true);
        assert_eq!(after["telegram"]["bot_token"], "x");
        assert_eq!(after["theme_mode"], "dark");
        // No file yet: just the key.
        let fresh: Value = serde_json::from_str(&merged(None, "agent_yolo", json!(true)).unwrap()).unwrap();
        assert_eq!(fresh, json!({"agent_yolo": true}));
        // A file that does not parse is left alone.
        assert!(merged(Some("{oops"), "agent_yolo", json!(true)).is_err());
        assert!(merged(Some("[1]"), "agent_yolo", json!(true)).is_err());
    }
}
