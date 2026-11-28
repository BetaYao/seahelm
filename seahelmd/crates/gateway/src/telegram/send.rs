//! `telegram.send`: a message or a file from this machine to the user's own
//! Telegram (`seahelm telegram send`). It goes only where the bot already
//! talks to the user — the default chat and the allowed users' private chats
//! — so an agent in a pane cannot post to anyone else.

use std::path::Path;

use serde_json::{json, Value};

use super::api::{self, Bot};
use super::format;
use crate::store::TelegramConfig;

/// Where a send may go: `asked` when it is the default chat or a numeric
/// allowed user, else the default chat (`super::default_chat`) when none was
/// asked for.
pub fn recipient(cfg: &TelegramConfig, asked: Option<&str>) -> Result<String, String> {
    let allowed: Vec<String> = cfg
        .default_chat_id
        .iter()
        .chain(cfg.allowed_users.iter())
        .map(|c| c.trim().trim_start_matches('@').to_string())
        .filter(|c| super::is_numeric_id(c))
        .collect();
    match asked.map(str::trim).filter(|c| !c.is_empty()) {
        Some(c) if allowed.iter().any(|a| a == c) => Ok(c.to_string()),
        Some(c) => Err(format!("{c} is not the default chat or an allowed user; seahelm sends only to those")),
        None => super::default_chat(cfg).ok_or_else(|| "no Telegram chat to send to: set a default chat or pair with the bot first".to_string()),
    }
}

/// What goes out, in order: messages ahead of the file, then the file's
/// caption. Text that fits under a file is its caption; longer text goes
/// first as messages of its own.
pub fn plan(text: &str, with_file: bool) -> (Vec<String>, Option<String>) {
    let text = text.trim();
    if text.is_empty() {
        return (Vec::new(), None);
    }
    if with_file && text.chars().count() <= api::MAX_CAPTION_LENGTH {
        return (Vec::new(), Some(text.to_string()));
    }
    (format::chunk(&format::html(text), format::MAX_MESSAGE_LENGTH), None)
}

/// A file this send may upload: a regular file within the bot's limit.
pub fn check_file(path: &Path) -> Result<(), String> {
    if !path.is_absolute() {
        return Err(format!("{}: give an absolute path", path.display()));
    }
    let meta = std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if !meta.is_file() {
        return Err(format!("{}: not a file", path.display()));
    }
    if meta.len() > api::MAX_UPLOAD_BYTES {
        return Err(format!("{}: {} MB is over Telegram's 50 MB limit for bots", path.display(), meta.len() / (1024 * 1024)));
    }
    Ok(())
}

/// Send it all; the ids of the messages that went out.
pub async fn run(bot: &Bot, chat: &str, text: &str, file: Option<&Path>, photo: bool) -> Result<Value, String> {
    if let Some(f) = file {
        check_file(f)?;
    }
    let (messages, caption) = plan(text, file.is_some());
    if messages.is_empty() && file.is_none() {
        return Err("nothing to send: give text or --file".into());
    }
    let mut ids = Vec::new();
    for html in &messages {
        let id = match bot.send_message(chat, html, true, &[]).await {
            Ok(id) => id,
            // Telegram is strict about its HTML: resend the same words flat.
            Err(e) if e.is_bad_request() => bot.send_message(chat, &format::strip_html(html), false, &[]).await.map_err(|e| e.to_string())?,
            Err(e) => return Err(e.to_string()),
        };
        ids.push(id);
    }
    if let Some(path) = file {
        let bytes = tokio::fs::read(path).await.map_err(|e| format!("{}: {e}", path.display()))?;
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "file".into());
        ids.push(bot.send_file(chat, &name, bytes, caption.as_deref(), photo).await.map_err(|e| e.to_string())?);
    }
    Ok(json!({"ok": true, "chat": chat, "message_ids": ids}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(default: Option<&str>, users: &[&str]) -> TelegramConfig {
        TelegramConfig { default_chat_id: default.map(Into::into), allowed_users: users.iter().map(|u| u.to_string()).collect(), ..Default::default() }
    }

    #[test]
    fn sends_to_the_default_chat_unless_told_otherwise() {
        let c = cfg(Some("-100"), &["42"]);
        assert_eq!(recipient(&c, None).unwrap(), "-100");
        assert_eq!(recipient(&c, Some("42")).unwrap(), "42");
        assert_eq!(recipient(&c, Some(" -100 ")).unwrap(), "-100");
    }

    #[test]
    fn refuses_a_chat_the_user_does_not_own() {
        let c = cfg(Some("-100"), &["42", "@someone"]);
        assert!(recipient(&c, Some("7")).is_err());
        // A username cannot be checked against a chat id: never a target.
        assert!(recipient(&c, Some("someone")).is_err());
    }

    #[test]
    fn falls_back_to_an_allowed_user_without_a_default_chat() {
        assert_eq!(recipient(&cfg(None, &["@someone", "42"]), None).unwrap(), "42");
        assert!(recipient(&cfg(None, &["@someone"]), None).is_err());
    }

    #[test]
    fn short_text_rides_as_the_caption() {
        assert_eq!(plan("look", true), (Vec::new(), Some("look".into())));
        let long = "x".repeat(api::MAX_CAPTION_LENGTH + 1);
        let (messages, caption) = plan(&long, true);
        assert_eq!((messages.len(), caption), (1, None));
    }

    #[test]
    fn text_alone_is_rendered_and_chunked() {
        assert_eq!(plan("**hi**", false).0, vec!["<b>hi</b>".to_string()]);
        let long = "line\n".repeat(2000);
        assert!(plan(&long, false).0.len() > 1);
        assert_eq!(plan("  ", false), (Vec::new(), None));
    }

    #[test]
    fn only_absolute_regular_files_go() {
        assert!(check_file(Path::new("relative.txt")).is_err());
        assert!(check_file(&std::env::temp_dir()).is_err());
        let f = std::env::temp_dir().join(format!("seahelm-send-test-{}", std::process::id()));
        std::fs::write(&f, b"x").unwrap();
        assert!(check_file(&f).is_ok());
        let _ = std::fs::remove_file(f);
    }
}
