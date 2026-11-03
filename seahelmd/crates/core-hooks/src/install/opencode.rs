//! OpenCode: a plugin (`OpenCodePluginInstaller.swift`) that reports session
//! lifecycle with opencode's own session id and per-session directory,
//! mirrors its native `question` tool into seahelm's question card, and
//! registers a `seahelm_suggest` tool.
//!
//! A tool rather than a hook, because opencode's plugin API has no
//! Claude-shaped Stop hook whose answer is consumed. Note `plugins/`,
//! plural: opencode's docs say `plugin/`, but the loader reads `plugins/`,
//! and a file in the singular directory is ignored without a word.
//!
//! On Unix the plugin is the Swift's, byte for byte (it reaches the socket
//! through `nc -U` and the `seahelm-suggest` script). On Windows neither
//! exists, so it hands every payload to the `seahelm-hook` binary on stdin.

use std::ffi::OsStr;
use std::io;
use std::path::{Path, PathBuf};

use super::{read_optional, write_atomic, Platform};

/// Ownership marker, unversioned on purpose: the overwrite guard checks
/// `contains`, so a versioned marker would make every older install look
/// foreign and freeze it.
pub const MARKER: &str = "// seahelm-suggest-plugin";

pub const FILE_NAME: &str = "seahelm-suggest.js";

const UNIX_PLUGIN: &str = include_str!("assets/opencode-plugin.js");
const WINDOWS_PLUGIN: &str = include_str!("assets/opencode-plugin-windows.js");

/// The plugin as it should be on disk. `hook_cmd` is only spelled into the
/// Windows build.
pub fn plugin_contents(platform: Platform, hook_cmd: &Path) -> String {
    match platform {
        Platform::Unix => UNIX_PLUGIN.to_string(),
        Platform::Windows => {
            let literal = serde_json::to_string(&hook_cmd.to_string_lossy()).unwrap_or_else(|_| "\"\"".into());
            WINDOWS_PLUGIN.replace("__SEAHELM_HOOK__", &literal)
        }
    }
}

/// opencode's config dir follows `XDG_CONFIG_HOME`, falling back to
/// `~/.config`; installing anywhere else misses a customized opencode.
pub fn plugins_dir(home: &Path, xdg_config_home: Option<&OsStr>) -> PathBuf {
    let base = match xdg_config_home.filter(|x| !x.is_empty()) {
        Some(xdg) => PathBuf::from(xdg),
        None => home.join(".config"),
    };
    base.join("opencode").join("plugins")
}

/// The plugin file's new contents, or None when it is already current —
/// or is someone else's file that happens to share the name (users keep
/// their own plugins here, symlinked ones included).
pub fn reconcile_plugin(old: Option<&str>, platform: Platform, hook_cmd: &Path) -> Option<String> {
    let desired = plugin_contents(platform, hook_cmd);
    match old {
        Some(existing) if existing == desired || !existing.contains(MARKER) => None,
        _ => Some(desired),
    }
}

/// Install into `dir`; `Ok(true)` when the plugin was written.
pub fn install_into(dir: &Path, hook_cmd: &Path, platform: Platform) -> io::Result<bool> {
    let path = dir.join(FILE_NAME);
    match reconcile_plugin(read_optional(&path).as_deref(), platform, hook_cmd) {
        Some(new) => write_atomic(&path, &new).map(|_| true),
        None => Ok(false),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hook() -> &'static Path {
        Path::new("/u/.local/bin/seahelm-hook")
    }

    fn unix() -> String {
        plugin_contents(Platform::Unix, hook())
    }

    #[test]
    fn test_installs_plugin_file() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("plugins");
        assert!(install_into(&dir, hook(), Platform::Unix).unwrap());
        assert!(dir.join(FILE_NAME).is_file());
        assert!(!install_into(&dir, hook(), Platform::Unix).unwrap());
    }

    #[test]
    fn test_rewrites_our_own_stale_plugin() {
        let tmp = tempfile::tempdir().unwrap();
        let js = tmp.path().join(FILE_NAME);
        std::fs::write(&js, "// seahelm-suggest-plugin v1 — stale\nexport const Old = 1\n").unwrap();
        assert!(install_into(tmp.path(), hook(), Platform::Unix).unwrap());
        assert!(std::fs::read_to_string(&js).unwrap().contains("seahelm_suggest"));
    }

    #[test]
    fn test_leaves_foreign_plugin_alone() {
        let tmp = tempfile::tempdir().unwrap();
        let js = tmp.path().join(FILE_NAME);
        let foreign = "export const NotOurs = async () => ({})\n";
        std::fs::write(&js, foreign).unwrap();
        assert!(!install_into(tmp.path(), hook(), Platform::Unix).unwrap());
        assert_eq!(std::fs::read_to_string(&js).unwrap(), foreign);
    }

    #[test]
    fn test_installs_into_plural_plugins_directory_under_xdg_config_home() {
        assert_eq!(plugins_dir(Path::new("/h"), None), Path::new("/h/.config/opencode/plugins"));
        assert_eq!(plugins_dir(Path::new("/h"), Some(OsStr::new(""))), Path::new("/h/.config/opencode/plugins"));
        assert_eq!(plugins_dir(Path::new("/h"), Some(OsStr::new("/x"))), Path::new("/x/opencode/plugins"));
    }

    #[test]
    fn test_plugin_calls_the_installed_suggest_script_and_declares_the_tool() {
        let js = unix();
        assert!(js.contains("seahelm_suggest"));
        assert!(js.contains("/.local/bin/seahelm-suggest"));
        assert!(js.contains("${SCRIPT} ${options}"));
        assert!(!js.contains("u0024"));
        assert!(js.contains(r"printf '%s\n' ${req} | nc -U ${SOCK}"));
    }

    #[test]
    fn test_plugin_forwards_question_tool_calls() {
        for js in [unix(), plugin_contents(Platform::Windows, hook())] {
            assert!(js.contains("\"tool.execute.before\""));
            assert!(js.contains("\"tool.execute.after\""));
            assert!(js.contains("AskUserQuestion"));
            assert!(js.contains("tool_use_end"));
            assert!(js.contains("q.multiple"));
        }
    }

    #[test]
    fn test_tracks_opencodes_own_session_id_via_lifecycle_events() {
        for js in [unix(), plugin_contents(Platform::Windows, hook())] {
            assert!(js.contains("event: async ({ event }) =>"));
            assert!(js.contains("\"session.created\""));
            assert!(js.contains("\"session.idle\""));
            assert!(js.contains("event.properties?.sessionID"));
            assert!(js.contains("input.sessionID"));
        }
    }

    #[test]
    fn test_excludes_subagent_sessions_from_idle_reporting() {
        let js = unix();
        assert!(js.contains("parentID"));
        assert!(js.contains("subagentSessions"));
    }

    #[test]
    fn test_plugin_reports_the_per_session_directory() {
        for js in [unix(), plugin_contents(Platform::Windows, hook())] {
            assert!(js.contains("dirBySession"));
            assert!(js.contains("info.directory"));
            assert!(js.contains("dirBySession.get(sessionId)"));
            assert!(!js.contains("cwd: directory ?? \"\""));
        }
    }

    #[test]
    fn the_unix_plugin_is_the_swift_ones() {
        let js = unix();
        assert!(js.starts_with("// seahelm-suggest-plugin v4 — managed by seahelm."));
        assert!(js.ends_with("  }\n}"));
    }

    #[test]
    fn the_windows_plugin_goes_through_the_hook_binary() {
        let js = plugin_contents(Platform::Windows, Path::new(r"C:\Program Files\seahelm\seahelm-hook.exe"));
        assert!(js.contains(MARKER));
        assert!(js.contains(r#"const HOOK = "C:\\Program Files\\seahelm\\seahelm-hook.exe""#));
        assert!(js.contains("${HOOK} opencode < ${new Response(payload)}"));
        assert!(!js.contains("nc -U"));
        assert!(!js.contains("/bin/sh"));
        assert!(!js.contains("__SEAHELM_HOOK__"));
    }
}
