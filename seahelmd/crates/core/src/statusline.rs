//! Claude Code reports its rate limits only inside the statusline payload,
//! so a statusline command has to tee that payload somewhere the core can
//! read it (`usage::statusline_cache_path`). The macOS app does this with a
//! shell script (`ClaudeStatuslineBridgeInstaller`); this is the same bridge
//! for machines without the app, and for Windows, as a subcommand:
//!
//!   seahelm-core statusline [-- 'ORIGINAL COMMAND']
//!
//! It reads the payload, caches it when it carries rate limits (a payload
//! without them — a fresh session, an API-key or `-p` run — would blank the
//! readout, so it leaves the last one), then runs the user's own statusline
//! command on the same bytes and passes its output and exit status through.
//! With no original command it prints nothing.
//!
//! `install` wraps the user's `statusLine` in it, keeping the original
//! command in the settings themselves (after `--`), so it can never be lost.

use std::io::{Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};

use anyhow::{Context, Result};
use serde_json::{json, Map, Value};

use crate::install::{quote, Outcome};

/// The tee. Returns the exit code to leave with.
pub fn run(args: &[String]) -> i32 {
    let mut input = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut input);
    cache_payload(&input, &crate::usage::statusline_cache_path());
    let original = original_command(args);
    if original.trim().is_empty() {
        return 0;
    }
    run_original(&original, &input)
}

/// Everything after `--`, as one shell command line (the installer passes
/// it as one quoted word; several words are joined back with spaces).
pub fn original_command(args: &[String]) -> String {
    match args.iter().position(|a| a == "--") {
        Some(i) => args[i + 1..].join(" "),
        None => String::new(),
    }
}

/// Write the payload to `cache` atomically, but only one that carries rate
/// limits. Failures are swallowed: the statusline must still show.
pub fn cache_payload(input: &[u8], cache: &Path) -> bool {
    let text = String::from_utf8_lossy(input);
    if !(text.contains("\"five_hour\"") || text.contains("\"seven_day\"")) {
        return false;
    }
    let Some(dir) = cache.parent() else { return false };
    if std::fs::create_dir_all(dir).is_err() {
        return false;
    }
    let tmp = dir.join(format!(".claude-statusline.{}.tmp", std::process::id()));
    if std::fs::write(&tmp, input).is_err() {
        return false;
    }
    if std::fs::rename(&tmp, cache).is_err() {
        let _ = std::fs::remove_file(&tmp);
        return false;
    }
    true
}

/// Run the user's command through the shell Claude Code would have used,
/// with the payload on stdin, its stdout and stderr ours.
fn run_original(command: &str, input: &[u8]) -> i32 {
    let mut cmd = if cfg!(windows) {
        let mut c = Command::new("cmd");
        c.arg("/C").arg(command);
        c
    } else {
        let mut c = Command::new("/bin/sh");
        c.arg("-c").arg(command);
        c
    };
    cmd.stdin(Stdio::piped()).stdout(Stdio::inherit()).stderr(Stdio::inherit());
    let Ok(mut child) = cmd.spawn() else { return 1 };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(input);
    }
    child.wait().ok().and_then(|s| s.code()).unwrap_or(1)
}

/// The command `statusLine` gets: our exe, `statusline`, and the original
/// as one quoted word after `--` when there is one.
pub fn bridge_command(exe: &Path, original: &str) -> String {
    let head = format!("{} statusline", quote(&exe.to_string_lossy()));
    if original.trim().is_empty() {
        head
    } else {
        format!("{head} -- {}", quote_word(original))
    }
}

/// One shell word holding `s` exactly: single quotes (POSIX shells, Git Bash
/// on Windows, where Claude Code runs its commands).
pub fn quote_word(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// The inverse of `quote_word` for what follows `--` in our own command.
pub fn unquote_word(s: &str) -> Option<String> {
    let s = s.trim();
    let mut out = String::new();
    let mut rest = s;
    while !rest.is_empty() {
        let body = rest.strip_prefix('\'')?;
        let end = body.find('\'')?;
        out.push_str(&body[..end]);
        rest = &body[end + 1..];
        if let Some(r) = rest.strip_prefix(r"\'") {
            out.push('\'');
            rest = r;
        }
    }
    Some(out)
}

/// The macOS app's bridge script (`…/seahelm/claude-statusline-bridge.sh`):
/// it feeds the same cache, so it is left alone. A legacy amux bridge shares
/// the filename but not the directory, and still gets wrapped.
fn is_app_bridge(command: &str) -> bool {
    command.contains("seahelm/claude-statusline-bridge")
}

/// Ours: `<exe> statusline` with or without `-- …`.
fn parse_ours(command: &str) -> Option<String> {
    let at = command.find(" statusline")?;
    let after = &command[at + " statusline".len()..];
    if !command[..at].contains("seahelm-core") {
        return None;
    }
    if after.trim().is_empty() {
        return Some(String::new());
    }
    unquote_word(after.trim_start().strip_prefix("--")?)
}

/// Wrap `~/.claude/settings.json`'s `statusLine` in the bridge. The rules
/// are the hooks': an unreadable file is left as it is; the app's bridge is
/// left alone; ours is migrated in place when the exe moved; a second run
/// changes nothing; every other key stays where it was.
pub fn install(settings: &Path, exe: &Path) -> Result<Outcome> {
    let mut root = match std::fs::read_to_string(settings) {
        Ok(text) if text.trim().is_empty() => Value::Object(Map::new()),
        Ok(text) => match serde_json::from_str::<Value>(&text) {
            Ok(v @ Value::Object(_)) => v,
            Ok(_) => return Ok(Outcome::Unreadable("not a JSON object".into())),
            Err(e) => return Ok(Outcome::Unreadable(format!("not JSON: {e}"))),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Value::Object(Map::new()),
        Err(e) => return Err(e).with_context(|| format!("read {}", settings.display())),
    };
    let obj = root.as_object_mut().unwrap();
    let mut status_line = match obj.get("statusLine") {
        None | Some(Value::Null) => Map::new(),
        Some(Value::Object(m)) => m.clone(),
        Some(_) => return Ok(Outcome::Unreadable("`statusLine` is not an object".into())),
    };
    let is_command = status_line.get("type").and_then(Value::as_str) == Some("command");
    let current = if is_command { status_line.get("command").and_then(Value::as_str).unwrap_or("").to_string() } else { String::new() };
    if is_app_bridge(&current) {
        return Ok(Outcome::Unchanged);
    }
    let original = parse_ours(&current).unwrap_or(current);
    let wanted = bridge_command(exe, &original);
    if is_command && status_line.get("command").and_then(Value::as_str) == Some(wanted.as_str()) {
        return Ok(Outcome::Unchanged);
    }
    status_line.insert("type".into(), json!("command"));
    status_line.insert("command".into(), json!(wanted));
    obj.insert("statusLine".into(), Value::Object(status_line));
    let mut text = serde_json::to_string_pretty(&root)?;
    text.push('\n');
    crate::install::write_atomic(settings, &text)?;
    Ok(Outcome::Written)
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXE: &str = "/opt/seahelm/bin/seahelm-core";

    /// The exe as the installer writes it: bare where a shell reads it as
    /// one word, double-quoted on Windows (`install::quote`).
    fn exe(path: &str) -> String {
        crate::install::quote(path)
    }

    fn read(p: &Path) -> Value {
        serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
    }

    fn command(p: &Path) -> String {
        read(p)["statusLine"]["command"].as_str().unwrap().to_string()
    }

    #[test]
    fn installs_wrapper_and_preserves_existing_command() {
        let dir = tempfile::tempdir().unwrap();
        let s = dir.path().join("settings.json");
        std::fs::write(&s, r#"{"model":"opus","statusLine":{"type":"command","command":"bash ~/.claude/my status.sh","padding":0}}"#).unwrap();
        assert_eq!(install(&s, Path::new(EXE)).unwrap(), Outcome::Written);
        let v = read(&s);
        assert_eq!(v["model"], "opus");
        assert_eq!(v["statusLine"]["padding"], 0);
        assert_eq!(command(&s), format!("{} statusline -- 'bash ~/.claude/my status.sh'", exe(EXE)));
        assert_eq!(parse_ours(&command(&s)).unwrap(), "bash ~/.claude/my status.sh");
    }

    #[test]
    fn installs_when_no_status_line_configured() {
        let dir = tempfile::tempdir().unwrap();
        let s = dir.path().join(".claude").join("settings.json");
        assert_eq!(install(&s, Path::new(EXE)).unwrap(), Outcome::Written);
        assert_eq!(read(&s)["statusLine"], json!({"type": "command", "command": format!("{} statusline", exe(EXE))}));
    }

    #[test]
    fn the_apps_bridge_is_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let s = dir.path().join("settings.json");
        let text = r#"{"statusLine":{"type":"command","command":"/bin/sh '/Users/u/Library/Application Support/seahelm/claude-statusline-bridge.sh'"}}"#;
        std::fs::write(&s, text).unwrap();
        assert_eq!(install(&s, Path::new(EXE)).unwrap(), Outcome::Unchanged);
        assert_eq!(std::fs::read_to_string(&s).unwrap(), text);
    }

    #[test]
    fn wraps_legacy_amux_bridge_command() {
        let dir = tempfile::tempdir().unwrap();
        let s = dir.path().join("settings.json");
        std::fs::write(&s, r#"{"statusLine":{"type":"command","command":"/bin/sh '/Users/u/Library/Application Support/amux/claude-statusline-bridge.sh'"}}"#).unwrap();
        assert_eq!(install(&s, Path::new(EXE)).unwrap(), Outcome::Written);
        assert_eq!(parse_ours(&command(&s)).unwrap(), "/bin/sh '/Users/u/Library/Application Support/amux/claude-statusline-bridge.sh'");
    }

    #[test]
    fn second_run_is_a_no_op() {
        let dir = tempfile::tempdir().unwrap();
        let s = dir.path().join("settings.json");
        std::fs::write(&s, r#"{"statusLine":{"type":"command","command":"echo 'hi there'"}}"#).unwrap();
        assert_eq!(install(&s, Path::new(EXE)).unwrap(), Outcome::Written);
        let first = std::fs::read_to_string(&s).unwrap();
        assert_eq!(install(&s, Path::new(EXE)).unwrap(), Outcome::Unchanged);
        assert_eq!(std::fs::read_to_string(&s).unwrap(), first);
        assert_eq!(parse_ours(&command(&s)).unwrap(), "echo 'hi there'");
    }

    #[test]
    fn a_moved_exe_keeps_the_original() {
        let dir = tempfile::tempdir().unwrap();
        let s = dir.path().join("settings.json");
        std::fs::write(&s, r#"{"statusLine":{"type":"command","command":"ccline"}}"#).unwrap();
        install(&s, Path::new(EXE)).unwrap();
        assert_eq!(install(&s, Path::new("/new/place/seahelm-core")).unwrap(), Outcome::Written);
        assert_eq!(command(&s), format!("{} statusline -- 'ccline'", exe("/new/place/seahelm-core")));
    }

    #[test]
    fn an_unreadable_settings_file_is_not_touched() {
        let dir = tempfile::tempdir().unwrap();
        let s = dir.path().join("settings.json");
        std::fs::write(&s, "{ not json").unwrap();
        assert!(matches!(install(&s, Path::new(EXE)).unwrap(), Outcome::Unreadable(_)));
        assert_eq!(std::fs::read_to_string(&s).unwrap(), "{ not json");
    }

    #[test]
    fn words_quote_and_unquote_exactly() {
        for s in ["plain", "with space", "it's", "a'b'c", "''", "$HOME `x` \"q\""] {
            assert_eq!(unquote_word(&quote_word(s)).unwrap(), s);
        }
    }

    #[test]
    fn payload_without_rate_limits_keeps_cached_rate_limits() {
        let dir = tempfile::tempdir().unwrap();
        let cache = dir.path().join("sub").join("claude-statusline.json");
        let with = br#"{"rate_limits":{"five_hour":{"used_percentage":10}}}"#;
        assert!(cache_payload(with, &cache));
        assert!(!cache_payload(br#"{"model":{"id":"x"}}"#, &cache));
        assert_eq!(std::fs::read(&cache).unwrap(), with);
    }

    #[cfg(unix)]
    #[test]
    fn the_original_gets_the_exact_input_bytes_and_its_status_passes_through() {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("seen");
        let input = b"{\"a\": \"spaces  and\\ttabs\"}\n";
        let original = format!("cat > '{}'; exit 3", out.display());
        assert_eq!(run_original(&original, input), 3);
        assert_eq!(std::fs::read(&out).unwrap(), input);
        let args: Vec<String> = ["--", "echo", "hi"].iter().map(|s| s.to_string()).collect();
        assert_eq!(original_command(&args), "echo hi");
        assert_eq!(original_command(&[]), "");
    }
}
