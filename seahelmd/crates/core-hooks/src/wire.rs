//! What the `seahelm-hook` shim puts on the wire, kept apart from the
//! binary so it can be tested without a socket.
//!
//! The shim reads a hook payload on stdin, tags it with the pane it ran in
//! and the agent that invoked it, and sends it to seahelm's control socket
//! as one JSON-RPC line:
//!
//! ```text
//! {"jsonrpc":"2.0","id":"h","method":"hook","params":{"seahelm_pane_id":…,"seahelm_source":…,…}}
//! ```
//!
//! The source is *declared* by whoever wired the hook (`seahelm-hook
//! claude-code`) rather than sniffed from the payload, because Claude
//! Code's payloads now carry the very keys that used to read as Codex-only.

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::Map;

/// The env var naming the socket (or, on Windows, the named pipe).
pub const SOCKET_ENV: &str = "SEAHELM_SOCKET_PATH";

/// How long the shim may spend on one event before it gives up.
pub const TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);

/// Where seahelm listens when `SEAHELM_SOCKET_PATH` is unset:
/// `~/.config/seahelm/seahelm.sock`, or on Windows the per-user pipe
/// `\\.\pipe\seahelm-<user>` (pipe names are machine-wide, so the user
/// name keeps two accounts apart).
pub fn default_socket_path(home: &Path, user: Option<&str>) -> PathBuf {
    if cfg!(windows) {
        let user = user.filter(|u| !u.is_empty()).unwrap_or("default");
        PathBuf::from(format!(r"\\.\pipe\seahelm-{user}"))
    } else {
        home.join(".config").join("seahelm").join("seahelm.sock")
    }
}

/// The socket the shim sends to, from its environment.
pub fn socket_path_from_env() -> PathBuf {
    match std::env::var_os(SOCKET_ENV).filter(|p| !p.is_empty()) {
        Some(p) => PathBuf::from(p),
        None => default_socket_path(&crate::home_dir(), std::env::var("USERNAME").ok().as_deref()),
    }
}

/// The pane a hook ran in: `SEAHELM_PANE_ID`, else `SEAHELMD_SESSION`
/// (the same value, kept by panes that predate the first export).
pub fn pane_id(seahelm_pane_id: Option<&str>, seahelmd_session: Option<&str>) -> Option<String> {
    seahelm_pane_id.filter(|s| !s.is_empty()).or(seahelmd_session.filter(|s| !s.is_empty())).map(str::to_string)
}

/// `payload` with `seahelm_pane_id` and `seahelm_source` put first; either
/// is left out when unknown or empty, never sent empty. A key the payload
/// already carries keeps the payload's value (the plugins send their own
/// pane id). None when the payload is not a JSON object: there is nothing
/// useful to forward.
pub fn splice(payload: &str, pane: Option<&str>, source: Option<&str>) -> Option<Map> {
    let Ok(Value::Object(body)) = serde_json::from_str::<Value>(payload.trim()) else { return None };
    let mut out = Map::new();
    if let Some(pane) = pane.filter(|p| !p.is_empty()) {
        out.insert("seahelm_pane_id".into(), pane.into());
    }
    if let Some(source) = source.filter(|s| !s.is_empty()) {
        out.insert("seahelm_source".into(), source.into());
    }
    for (k, v) in body {
        out.insert(k, v);
    }
    Some(out)
}

/// The request line for `params`, newline-terminated. Compact JSON, so a
/// pretty-printed payload cannot break the newline-delimited protocol.
pub fn request_line(params: Map) -> String {
    let req = serde_json::json!({"jsonrpc": "2.0", "id": "h", "method": "hook", "params": params});
    format!("{req}\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    // SeahelmHookInstallerTests, adapted: the script's shape is now this
    // splice and the request it builds.

    #[test]
    fn test_script_shape() {
        let params = splice(r#"{"hook_event_name":"Stop","session_id":"s","cwd":"/wt"}"#, Some("seahelm-repo-main"), Some("claude-code")).unwrap();
        let keys: Vec<&str> = params.keys().map(String::as_str).collect();
        assert_eq!(keys, vec!["seahelm_pane_id", "seahelm_source", "hook_event_name", "session_id", "cwd"]);
        let line = request_line(params);
        assert!(line.ends_with('\n') && line.matches('\n').count() == 1);
        assert!(line.contains(r#""method":"hook""#));
        assert!(line.contains(r#""id":"h""#));
        assert!(!line.contains("/webhook"));
    }

    #[test]
    fn untagged_calls_emit_no_empty_source() {
        let params = splice(r#"{"a":1}"#, Some("p"), None).unwrap();
        assert!(!params.contains_key("seahelm_source"));
        let params = splice(r#"{"a":1}"#, None, Some("")).unwrap();
        assert!(params.is_empty() || !params.contains_key("seahelm_pane_id"));
        assert!(!params.contains_key("seahelm_source"));
    }

    #[test]
    fn pretty_payloads_travel_as_one_line() {
        let line = request_line(splice("{\n  \"x\": \"a\\nb\"\n}\n", None, None).unwrap());
        assert_eq!(line.matches('\n').count(), 1);
    }

    #[test]
    fn non_objects_are_not_forwarded() {
        assert_eq!(splice("", Some("p"), Some("s")), None);
        assert_eq!(splice("[1]", Some("p"), Some("s")), None);
        assert_eq!(splice("not json", Some("p"), Some("s")), None);
    }

    #[test]
    fn the_pane_falls_back_to_the_seahelmd_session() {
        assert_eq!(pane_id(Some("a"), Some("b")).as_deref(), Some("a"));
        assert_eq!(pane_id(Some(""), Some("b")).as_deref(), Some("b"));
        assert_eq!(pane_id(None, None), None);
    }

    #[cfg(unix)]
    #[test]
    fn the_default_socket_is_under_the_config_dir() {
        assert_eq!(default_socket_path(Path::new("/h"), None), PathBuf::from("/h/.config/seahelm/seahelm.sock"));
    }
}
