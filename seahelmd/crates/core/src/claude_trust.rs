//! Claude Code asks "Do you trust this folder?" the first time it starts in
//! a directory, and waits there. A session the core starts in a directory
//! of its own making (First Mate's home, the research repository) has nobody
//! watching that screen, so the core marks those directories trusted itself
//! — those and nothing else.

use serde_json::{json, Value};
use std::path::Path;

/// Mark `dir` trusted in `~/.claude.json`, logging a failure.
pub fn trust(dir: &Path) {
    let Some(home) = std::env::var_os("HOME").map(std::path::PathBuf::from) else { return };
    if let Err(e) = trust_in(&home.join(".claude.json"), dir) {
        eprintln!("seahelm-core: could not mark {} trusted for Claude Code: {e}", dir.display());
    }
}

/// Mark `dir` trusted in Claude Code's own `~/.claude.json`
/// (`projects.<dir>.hasTrustDialogAccepted`), keeping every other key as it
/// is. Read-modify-rename; nothing is written when it is already trusted or
/// the file does not exist (no Claude Code here).
pub fn trust_in(file: &Path, dir: &Path) -> Result<(), String> {
    let Ok(text) = std::fs::read_to_string(file) else { return Ok(()) };
    let mut v: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let key = dir.canonicalize().unwrap_or_else(|_| dir.to_path_buf()).to_string_lossy().into_owned();
    let Some(root) = v.as_object_mut() else { return Err("not a JSON object".into()) };
    let projects = root.entry("projects").or_insert_with(|| json!({}));
    let Some(projects) = projects.as_object_mut() else { return Err("projects is not an object".into()) };
    let entry = projects.entry(key).or_insert_with(|| json!({}));
    if entry.get("hasTrustDialogAccepted").and_then(Value::as_bool) == Some(true) {
        return Ok(());
    }
    if let Some(o) = entry.as_object_mut() {
        o.insert("hasTrustDialogAccepted".into(), json!(true));
    }
    let tmp = file.with_extension(format!("json.seahelm-{}", std::process::id()));
    std::fs::write(&tmp, serde_json::to_string_pretty(&v).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    if let Ok(meta) = std::fs::metadata(file) {
        let _ = std::fs::set_permissions(&tmp, meta.permissions());
    }
    std::fs::rename(&tmp, file).map_err(|e| e.to_string())
}
