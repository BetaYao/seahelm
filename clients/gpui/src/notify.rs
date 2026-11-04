//! Delivering seahelm-core's notices, and the client's own event log.
//!
//! The core decides when a pane's turn deserves a banner (`pane.notice`:
//! fingerprint dedupe, cooldown, the stability gate, whether it was on
//! screen); the client only shows it, with what each platform has without
//! an app bundle: `osascript` on macOS, `notify-send` on Linux, a WinRT
//! toast through PowerShell on Windows.

use std::io::Write;
use std::process::{Command, Stdio};

use serde_json::{json, Value};

/// The banner for a `pane.notice`: the worktree and what happened, then
/// the agent's last words. None when the pane is the one on screen.
pub fn text(notice: &Value) -> Option<(String, String)> {
    if notice.get("is_target_visible").and_then(Value::as_bool).unwrap_or(false) {
        return None;
    }
    let s = |k: &str| notice.get(k).and_then(Value::as_str).unwrap_or_default();
    let worktree = std::path::Path::new(s("worktree_path")).file_name().and_then(|n| n.to_str()).unwrap_or("Seahelm");
    let what = match s("new_status") {
        "Idle" | "Exited" => "finished",
        "Waiting" | "Blocked" | "NeedsInput" => "needs you",
        "Error" => "hit an error",
        "Running" => "started",
        other => other,
    };
    let title = format!("{worktree} {what}");
    let words = [s("last_assistant_message"), s("last_message")].into_iter().find(|w| !w.trim().is_empty()).unwrap_or("");
    let mut body: String = words.split_whitespace().collect::<Vec<_>>().join(" ");
    if body.chars().count() > 200 {
        body = body.chars().take(199).collect::<String>() + "…";
    }
    Some((title, body))
}

/// Show a banner. Fire-and-forget; a platform without a notifier shows
/// nothing.
pub fn deliver(title: &str, body: &str) {
    let result = platform_deliver(title, body);
    if let Err(e) = result {
        eprintln!("seahelm-gpui: notification: {e}");
    }
}

#[cfg(target_os = "macos")]
fn platform_deliver(title: &str, body: &str) -> std::io::Result<()> {
    // AppleScript string literals: backslash and double quote escaped.
    let q = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"");
    let script = format!("display notification \"{}\" with title \"{}\"", q(body), q(title));
    Command::new("osascript").args(["-e", &script]).stdout(Stdio::null()).stderr(Stdio::null()).spawn().map(|_| ())
}

#[cfg(all(unix, not(target_os = "macos")))]
fn platform_deliver(title: &str, body: &str) -> std::io::Result<()> {
    Command::new("notify-send").args(["--app-name=Seahelm", title, body]).stdout(Stdio::null()).stderr(Stdio::null()).spawn().map(|_| ())
}

#[cfg(windows)]
fn platform_deliver(title: &str, body: &str) -> std::io::Result<()> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    // XML-escaped into a ToastGeneric template, shown under PowerShell's
    // app id (an unpackaged app has none of its own).
    let x = |s: &str| s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('\'', "&apos;").replace('"', "&quot;");
    let script = format!(
        "[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null;\
         [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > $null;\
         $x = New-Object Windows.Data.Xml.Dom.XmlDocument;\
         $x.LoadXml('<toast><visual><binding template=\"ToastGeneric\"><text>{}</text><text>{}</text></binding></visual></toast>');\
         [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}}\\WindowsPowerShell\\v1.0\\powershell.exe').Show([Windows.UI.Notifications.ToastNotification]::new($x))",
        x(title).replace('\'', "''"),
        x(body).replace('\'', "''"),
    );
    Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .creation_flags(CREATE_NO_WINDOW)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(|_| ())
}

/// The client's own record of what happened, for comparing a stretch of
/// use against the macOS app's (`~/.config/seahelm/gpui-events.jsonl`): one
/// JSON line per event, with the wall-clock time. Rolls over past 10 MB.
pub fn log(kind: &str, detail: Value) {
    let path = crate::platform::config_dir().join("gpui-events.jsonl");
    let at = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
    let mut line = json!({"at": at, "event": kind});
    if let (Some(o), Value::Object(d)) = (line.as_object_mut(), detail) {
        o.extend(d);
    }
    if std::fs::metadata(&path).map(|m| m.len() > 10 << 20).unwrap_or(false) {
        let _ = std::fs::rename(&path, path.with_extension("jsonl.1"));
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{line}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_notice_reads_as_its_worktree_and_what_happened() {
        let n = json!({"worktree_path": "/w/feat-x", "new_status": "Idle", "last_assistant_message": "Done.\n\nAll  tests pass.", "is_target_visible": false});
        assert_eq!(text(&n), Some(("feat-x finished".into(), "Done. All tests pass.".into())));
        let waiting = json!({"worktree_path": "/w/a", "new_status": "Waiting", "last_message": "Allow edit?"});
        assert_eq!(text(&waiting).unwrap().0, "a needs you");
    }

    #[test]
    fn a_notice_for_the_pane_on_screen_shows_nothing() {
        assert_eq!(text(&json!({"worktree_path": "/w/a", "new_status": "Idle", "is_target_visible": true})), None);
    }
}
