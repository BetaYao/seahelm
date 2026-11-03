//! Wiring each agent's own config to report its lifecycle to seahelm
//! (`*HooksSetup.swift`, `OpenCodePluginInstaller.swift`,
//! `PiExtensionInstaller.swift`, `AgentHookInstaller.swift`).
//!
//! Each installer is a pure reconcile — the file's current contents in,
//! the contents it should have out, or None when it already says that — and
//! a thin `install_*` that reads, reconciles and writes. Launch runs them on
//! every start, so "unchanged" must really mean no write: rewriting a
//! user's settings every launch churns them, and once appended a copy of our
//! hook each time.
//!
//! The rules every installer keeps: an entry someone else wrote is never
//! rewritten or removed; ours is recognised in every form we ever wrote
//! (the `seahelm-hook` command, the older `/webhook` HTTP hook) and migrated
//! in place; a file we cannot parse in the shape we expect is left alone
//! rather than clobbered (where the Swift did so — Claude's settings and
//! Cursor's hooks.json were rewritten from scratch, and still are).
//!
//! The hook command is the `seahelm-hook` binary's path. On macOS and Linux
//! the text written matches the Swift installers'; on Windows no command
//! goes through `/bin/sh` and no plugin uses `nc`.

use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::Map;

pub mod claude;
pub mod codex;
pub mod cursor;
pub mod merge;
pub mod opencode;
pub mod pi;

/// Which shell world the written commands must run in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Platform {
    /// macOS and Linux: commands may use `/bin/sh`, plugins `nc -U`.
    Unix,
    Windows,
}

impl Platform {
    pub fn current() -> Self {
        if cfg!(windows) {
            Platform::Windows
        } else {
            Platform::Unix
        }
    }
}

/// The hook binary as the first word of a command line. Unquoted on Unix,
/// as the Swift wrote it (and as the existing configs on disk say); quoted
/// on Windows when the path has a space, which `Program Files` does.
pub(crate) fn command_word(hook_cmd: &Path, platform: Platform) -> String {
    let s = hook_cmd.to_string_lossy().into_owned();
    if platform == Platform::Windows && s.contains(char::is_whitespace) {
        format!("\"{s}\"")
    } else {
        s
    }
}

/// A JSON value with every object's keys sorted, recursively: Swift's
/// `.sortedKeys`, so the files we write are stable and diffable.
pub(crate) fn sorted(v: &Value) -> Value {
    match v {
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            Value::Object(keys.into_iter().map(|k| (k.clone(), sorted(&m[k]))).collect())
        }
        Value::Array(a) => Value::Array(a.iter().map(sorted).collect()),
        other => other.clone(),
    }
}

/// Pretty JSON with sorted keys, as the Swift wrote config files.
pub(crate) fn pretty_sorted(root: &Map) -> String {
    serde_json::to_string_pretty(&sorted(&Value::Object(root.clone()))).unwrap_or_default()
}

/// The JSON object a config file holds, or None when it is missing or not one.
pub(crate) fn parse_object(text: Option<&str>) -> Option<Map> {
    match serde_json::from_str::<Value>(text?) {
        Ok(Value::Object(m)) => Some(m),
        _ => None,
    }
}

/// A file's text, None when it does not exist (or is not UTF-8).
pub(crate) fn read_optional(path: &Path) -> Option<String> {
    std::fs::read_to_string(path).ok()
}

/// Write via a sibling temp file and a rename, so a crash never leaves a
/// half-written config.
pub(crate) fn write_atomic(path: &Path, contents: &str) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(format!(".seahelm-tmp-{}", std::process::id()));
    let tmp = PathBuf::from(tmp);
    std::fs::write(&tmp, contents)?;
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

/// Reconcile one file in place: `Ok(true)` when it was written.
pub(crate) fn reconcile_file(path: &Path, reconcile: impl FnOnce(Option<&str>) -> Option<String>) -> io::Result<bool> {
    let old = read_optional(path);
    match reconcile(old.as_deref()) {
        Some(new) => write_atomic(path, &new).map(|_| true),
        None => Ok(false),
    }
}

/// Claude Code: `~/.claude/settings.json`.
pub fn install_claude(home: &Path, hook_cmd: &Path) -> io::Result<bool> {
    claude::install(home, hook_cmd, Platform::current())
}

/// Codex: `~/.codex/config.toml` (`[features].hooks`) and `~/.codex/hooks.json`.
pub fn install_codex(home: &Path, hook_cmd: &Path) -> io::Result<bool> {
    codex::install(home, hook_cmd, Platform::current())
}

/// Cursor: `~/.cursor/hooks.json`.
pub fn install_cursor(home: &Path, hook_cmd: &Path) -> io::Result<bool> {
    cursor::install(home, hook_cmd, Platform::current())
}

/// OpenCode: `seahelm-suggest.js` in `$XDG_CONFIG_HOME/opencode/plugins`
/// (else `~/.config/opencode/plugins`).
pub fn install_opencode(home: &Path, hook_cmd: &Path) -> io::Result<bool> {
    let xdg = std::env::var_os("XDG_CONFIG_HOME");
    let dir = opencode::plugins_dir(home, xdg.as_deref());
    opencode::install_into(&dir, hook_cmd, Platform::current())
}

/// Pi: `~/.pi/agent/extensions/seahelm.js`, registered in its settings.
pub fn install_pi(home: &Path, _hook_cmd: &Path) -> io::Result<bool> {
    pi::install_into(&pi::agent_dir(home), Platform::current())
}

/// One installed component and whether it landed (`ok` is "configured
/// afterwards", not "changed": an already-configured agent is a success).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstallStep {
    pub name: &'static str,
    pub detail: String,
    pub ok: bool,
}

/// Install hooks for the given agent manifest ids (`claude`, `codex`,
/// `cursor`, `opencode`, `pi`; case-insensitive), reporting each step.
/// The Swift's other launch-time pieces — the suggest script, the python
/// `seahelm` CLI, Claude's statusline bridge and the skill — belong to the
/// app, not to the hook path, and are not installed here.
pub fn install_agents(agents: &[&str], home: &Path, hook_cmd: &Path) -> Vec<InstallStep> {
    if agents.is_empty() {
        return Vec::new();
    }
    let wanted: Vec<String> = agents.iter().map(|a| a.to_lowercase()).collect();
    let has = |id: &str| wanted.iter().any(|a| a == id);
    let mut steps = vec![InstallStep {
        name: "Hook bridge",
        detail: hook_cmd.to_string_lossy().into_owned(),
        ok: hook_cmd.is_file(),
    }];
    let mut step = |name: &'static str, detail: &str, result: io::Result<bool>| {
        steps.push(InstallStep { name, detail: detail.into(), ok: result.is_ok() });
    };
    if has("claude") {
        step("Claude Code hooks", "~/.claude/settings.json", install_claude(home, hook_cmd));
    }
    if has("codex") {
        step("Codex hooks", "~/.codex/hooks.json", install_codex(home, hook_cmd));
    }
    if has("cursor") {
        step("Cursor hooks", "~/.cursor/hooks.json", install_cursor(home, hook_cmd));
    }
    if has("opencode") {
        step("OpenCode plugin", "~/.config/opencode/plugins", install_opencode(home, hook_cmd));
    }
    if has("pi") {
        step("Pi extension", "~/.pi/agent", install_pi(home, hook_cmd));
    }
    steps
}

/// Every agent's hooks: what launch installs when the config names none.
pub const ALL_AGENTS: [&str; 5] = ["claude", "codex", "cursor", "opencode", "pi"];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn installing_every_agent_into_an_empty_home_succeeds_and_settles() {
        let home = tempfile::tempdir().unwrap();
        let hook = home.path().join("bin").join("seahelm-hook");
        std::fs::create_dir_all(hook.parent().unwrap()).unwrap();
        std::fs::write(&hook, "").unwrap();
        let steps = install_agents(&ALL_AGENTS, home.path(), &hook);
        assert_eq!(steps.len(), 6);
        assert!(steps.iter().all(|s| s.ok), "{steps:?}");
        // Everything is in place: a second launch writes nothing.
        let p = Platform::current();
        assert!(!claude::install(home.path(), &hook, p).unwrap());
        assert!(!codex::install(home.path(), &hook, p).unwrap());
        assert!(!cursor::install(home.path(), &hook, p).unwrap());
        assert!(!pi::install_into(&pi::agent_dir(home.path()), p).unwrap());
    }

    #[test]
    fn windows_quotes_a_hook_path_with_spaces() {
        let path = Path::new(r"C:\Program Files\seahelm\seahelm-hook.exe");
        assert_eq!(command_word(path, Platform::Windows), "\"C:\\Program Files\\seahelm\\seahelm-hook.exe\"");
        assert_eq!(command_word(Path::new("/u/bin/seahelm-hook"), Platform::Unix), "/u/bin/seahelm-hook");
    }
}
