//! Pi: an extension that reports agent lifecycle (`PiExtensionInstaller.swift`).
//!
//! Two non-destructive steps: write `~/.pi/agent/extensions/seahelm.js`,
//! and register its path in `~/.pi/agent/settings.json`'s `extensions`
//! array — Pi loads extensions from an explicit list, not by scanning.
//! Project-trust waits stay a screen-scan concern: Pi's `project_trust`
//! handler must *return* a decision, and subscribing would hijack it.
//!
//! The extension opens the socket itself through `node:net` (Pi gives
//! extensions no shell). `node:net` speaks Windows named pipes too, so the
//! Windows build differs only in the default address.

use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{pretty_sorted, read_optional, reconcile_file, write_atomic, Platform};
use crate::Map;

/// Ownership marker, unversioned for the same reason as OpenCode's.
pub const MARKER: &str = "// seahelm-pi-extension";

const UNIX_EXTENSION: &str = include_str!("assets/pi-extension.js");
const WINDOWS_EXTENSION: &str = include_str!("assets/pi-extension-windows.js");

pub fn extension_contents(platform: Platform) -> &'static str {
    match platform {
        Platform::Unix => UNIX_EXTENSION,
        Platform::Windows => WINDOWS_EXTENSION,
    }
}

/// `~/.pi/agent`, Pi's user config dir.
pub fn agent_dir(home: &Path) -> PathBuf {
    home.join(".pi").join("agent")
}

pub fn extension_path(agent_dir: &Path) -> PathBuf {
    agent_dir.join("extensions").join("seahelm.js")
}

pub fn settings_path(agent_dir: &Path) -> PathBuf {
    agent_dir.join("settings.json")
}

/// The extension file's new contents, or None when it is current or is
/// someone else's file of the same name.
pub fn reconcile_extension(old: Option<&str>, platform: Platform) -> Option<String> {
    let desired = extension_contents(platform);
    match old {
        Some(existing) if existing == desired || !existing.contains(MARKER) => None,
        _ => Some(desired.to_string()),
    }
}

/// settings.json with `extension_path` appended to `extensions`, every
/// other key kept; None when it is already registered — or when the file
/// is not a JSON object or its `extensions` not an array: the user's file
/// wins over our registration.
pub fn reconcile_settings(old: Option<&str>, extension_path: &str) -> Option<String> {
    let mut root: Map = match old {
        None => Map::new(),
        Some(text) => match serde_json::from_str::<Value>(text) {
            Ok(Value::Object(m)) => m,
            _ => return None,
        },
    };
    let mut extensions = match root.get("extensions") {
        None => Vec::new(),
        Some(Value::Array(a)) => a.clone(),
        Some(_) => return None,
    };
    if extensions.iter().any(|e| e.as_str() == Some(extension_path)) {
        return None;
    }
    extensions.push(extension_path.into());
    root.insert("extensions".into(), Value::Array(extensions));
    Some(pretty_sorted(&root))
}

/// Install under `agent_dir`; `Ok(true)` when either file was written.
pub fn install_into(agent_dir: &Path, platform: Platform) -> io::Result<bool> {
    let ext = extension_path(agent_dir);
    let wrote_ext = match reconcile_extension(read_optional(&ext).as_deref(), platform) {
        Some(new) => write_atomic(&ext, &new).map(|_| true),
        None => Ok(false),
    };
    let ext_str = ext.to_string_lossy().into_owned();
    let wrote_settings = reconcile_file(&settings_path(agent_dir), |old| reconcile_settings(old, &ext_str));
    Ok(wrote_ext? | wrote_settings?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn settings(dir: &Path) -> Value {
        serde_json::from_str(&std::fs::read_to_string(settings_path(dir)).unwrap()).unwrap()
    }

    #[test]
    fn test_installs_extension_and_registers_in_settings() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("agent");
        assert!(install_into(&dir, Platform::Unix).unwrap());
        let ext = extension_path(&dir);
        let js = std::fs::read_to_string(&ext).unwrap();
        assert!(js.contains("agent_settled"));
        assert!(js.contains("export default function seahelm"));
        assert_eq!(settings(&dir)["extensions"], json!([ext.to_string_lossy()]));
        assert!(!install_into(&dir, Platform::Unix).unwrap());
    }

    #[test]
    fn test_preserves_existing_settings_keys_and_extensions() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        std::fs::write(settings_path(dir), json!({"model": "gpt-5", "extensions": ["/home/me/.pi/agent/extensions/mine.js"]}).to_string())
            .unwrap();
        assert!(install_into(dir, Platform::Unix).unwrap());
        let s = settings(dir);
        assert_eq!(s["model"], "gpt-5");
        let exts = s["extensions"].as_array().unwrap();
        assert!(exts.contains(&json!("/home/me/.pi/agent/extensions/mine.js")));
        assert_eq!(exts.len(), 2);
    }

    #[test]
    fn test_does_not_clobber_unparseable_settings() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        let raw = "{ this is not valid json, // with a comment\n}";
        std::fs::write(settings_path(dir), raw).unwrap();
        let _ = install_into(dir, Platform::Unix);
        assert_eq!(std::fs::read_to_string(settings_path(dir)).unwrap(), raw);
        assert!(extension_path(dir).is_file(), "the extension still installs");
    }

    #[test]
    fn test_reports_pis_own_session_id_and_path_not_the_pane_id() {
        for js in [extension_contents(Platform::Unix), extension_contents(Platform::Windows)] {
            assert!(js.contains("ctx.sessionManager.getSessionId"));
            assert!(js.contains("ctx.sessionManager.getSessionFile"));
            assert!(js.contains("session_path"));
            assert!(js.contains("(e, ctx) =>"));
        }
    }

    #[test]
    fn test_leaves_foreign_extension_file_alone() {
        let tmp = tempfile::tempdir().unwrap();
        let ext = extension_path(tmp.path());
        std::fs::create_dir_all(ext.parent().unwrap()).unwrap();
        let foreign = "export default function notOurs() {}\n";
        std::fs::write(&ext, foreign).unwrap();
        let _ = install_into(tmp.path(), Platform::Unix);
        assert_eq!(std::fs::read_to_string(&ext).unwrap(), foreign);
    }

    #[test]
    fn a_non_array_extensions_key_is_left_alone() {
        assert_eq!(reconcile_settings(Some(r#"{"extensions": "x"}"#), "/e.js"), None);
    }

    #[test]
    fn the_windows_extension_dials_the_named_pipe() {
        let js = extension_contents(Platform::Windows);
        assert!(js.contains(MARKER));
        assert!(js.contains(r"`\\\\.\\pipe\\seahelm-${process.env.USERNAME"));
        assert!(!js.contains("seahelm.sock"));
    }
}
