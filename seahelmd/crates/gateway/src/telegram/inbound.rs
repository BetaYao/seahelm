//! What one inbound message is: an order, a `/start`, group talk that was not
//! aimed at the bot, or rule input. Pure; the adapter acts on the answer.

use super::api::{Document, Message, PhotoSize};
use crate::store::TelegramConfig;

/// An order, and who gave it.
#[derive(Debug, Clone, PartialEq)]
pub struct Order {
    pub body: String,
    /// Telegram user id, stable where usernames are not.
    pub sender_id: i64,
    pub sender_name: String,
}

/// Whether one message is an order, and from whom. Two gates:
///
/// 1. **Sender**: someone on the allowlist. Channel posts and anonymous
///    admins carry no user and so are never orders, only signals.
/// 2. **Chat**: in a private chat everything is an order, prose included —
///    there is nobody else to talk to. In a group it must be aimed at the
///    bot: a `/command`, a line starting `@thebot`, or a reply to one of the
///    bot's messages. Bare prose in a shared group must not steer an agent.
///
/// No echo guard: a bot's own messages never come back as updates.
///
/// `body` is what the pane should see (downloaded media paths joined with
/// any caption); classification uses the same gates on it.
pub fn order(message: &Message, body: &str, config: &TelegramConfig, bot_username: Option<&str>) -> Option<Order> {
    let text = body.trim();
    if text.is_empty() {
        return None;
    }
    let from = message.from.as_ref()?;
    if !config.allows(from.id, from.username.as_deref()) {
        return None;
    }
    let body = strip_bot_mention(text, bot_username);
    let make = |body: String| Order { body, sender_id: from.id, sender_name: from.display_name() };
    if message.chat.is_private() || is_slash_command(&body) {
        return Some(make(body));
    }
    addressed_prose(&body, message, bot_username).map(make)
}

/// A line from someone on the allowlist, in a group, that would have been an
/// order anywhere the bot is the only listener: the one case `order` said no
/// over *where* it was said rather than *who* said it.
pub fn is_unaddressed_order(message: &Message, config: &TelegramConfig, bot_username: Option<&str>) -> bool {
    let Some(text) = message.body().map(str::trim).filter(|t| !t.is_empty()) else { return false };
    let Some(from) = &message.from else { return false };
    if !config.allows(from.id, from.username.as_deref()) || message.chat.is_private() {
        return false;
    }
    let body = strip_bot_mention(text, bot_username);
    !is_slash_command(&body) && addressed_prose(&body, message, bot_username).is_none()
}

/// Both ways in, and why there is a door at all. The hint is itself one of
/// the bot's messages, so "reply to this" can be done on the spot.
pub fn addressing_hint(bot_username: Option<&str>) -> String {
    let ways = match bot_username.filter(|u| !u.is_empty()) {
        Some(u) => format!("Reply to this message, or start the line with @{u}"),
        None => "Reply to this message".to_string(),
    };
    format!("{ways} and I'll send it on. A bare line in a group I leave alone — somebody else's sentence must not steer an agent.")
}

/// How long a group goes between addressing hints.
pub const ADDRESSING_HINT_WINDOW: f64 = 600.0;

/// Bot commands are `/name` (optionally `/name@bot`); a path is not one.
pub fn is_slash_command(body: &str) -> bool {
    let trimmed = body.trim();
    if !trimmed.starts_with('/') {
        return false;
    }
    let token = trimmed.split([' ', '\n']).next().unwrap_or(trimmed);
    let name = token.split('@').next().unwrap_or(token);
    let rest = &name[1..];
    if rest.is_empty() {
        return name == "/";
    }
    rest.chars().all(|c| c.is_alphanumeric() || c == '_')
}

/// Group prose aimed at the bot, with the address taken off; None when it
/// was not aimed at it. A leading `@thebot` (stripped, so the agent is not
/// handed the bot's name) or a reply to one of the bot's messages. A mention
/// with nothing after it is someone talking *about* the bot.
pub fn addressed_prose(body: &str, message: &Message, bot_username: Option<&str>) -> Option<String> {
    let name = bot_username.filter(|n| !n.is_empty())?;
    let mention = format!("@{name}");
    if body.len() >= mention.len() && body.is_char_boundary(mention.len()) && body[..mention.len()].eq_ignore_ascii_case(&mention) {
        let rest = body[mention.len()..].trim();
        return (!rest.is_empty()).then(|| rest.to_string());
    }
    let replied = message.reply_to_message.as_ref()?.from.as_ref()?.username.as_deref()?;
    replied.eq_ignore_ascii_case(name).then(|| body.to_string())
}

/// `/status@seahelm_bot` is how a group with several bots says which one; the
/// suffix means nothing to the language.
pub fn strip_bot_mention(text: &str, bot_username: Option<&str>) -> String {
    let Some(name) = bot_username.filter(|n| !n.is_empty() && text.starts_with('/')) else { return text.to_string() };
    let (head, rest) = match text.split_once(' ') {
        Some((h, r)) => (h, Some(r)),
        None => (text, None),
    };
    let suffix = format!("@{name}");
    let head = if head.len() > suffix.len() && head.is_char_boundary(head.len() - suffix.len()) && head[head.len() - suffix.len()..].eq_ignore_ascii_case(&suffix) {
        &head[..head.len() - suffix.len()]
    } else {
        head
    };
    match rest {
        Some(r) => format!("{head} {r}"),
        None => head.to_string(),
    }
}

/// What a rule's `from` pattern sees: a user's `@username` (or id), a
/// channel's `@username` or title.
pub fn signal_sender(message: &Message) -> String {
    if let Some(from) = &message.from {
        return match from.username.as_deref().filter(|u| !u.is_empty()) {
            Some(u) => format!("@{u}"),
            None => from.id.to_string(),
        };
    }
    let chat = message.sender_chat.as_ref().unwrap_or(&message.chat);
    if let Some(u) = chat.username.as_deref().filter(|u| !u.is_empty()) {
        return format!("@{u}");
    }
    if let Some(t) = chat.title.as_deref().filter(|t| !t.is_empty()) {
        return t.to_string();
    }
    chat.id.to_string()
}

/// The payload of a `/start`, or None when the text is not one. A deep link
/// `t.me/<bot>?start=ABC` arrives as the literal text `/start ABC`; a bare
/// Start button sends `/start`, which is `Some("")`.
pub fn start_payload(text: &str) -> Option<String> {
    let t = text.trim();
    if t == "/start" {
        return Some(String::new());
    }
    t.strip_prefix("/start ").map(|p| p.trim().to_string())
}

// MARK: media

const IMAGE_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"];

/// The largest size Telegram attached: by file size, else by area.
pub fn preferred_photo(sizes: &[PhotoSize]) -> Option<&PhotoSize> {
    sizes.iter().max_by_key(|p| p.file_size.unwrap_or(p.width * p.height))
}

pub fn is_image_document(d: &Document) -> bool {
    if d.mime_type.as_deref().is_some_and(|m| m.to_ascii_lowercase().starts_with("image/")) {
        return true;
    }
    d.file_name.as_deref().and_then(|n| n.rsplit_once('.')).is_some_and(|(_, ext)| IMAGE_EXTENSIONS.contains(&ext.to_ascii_lowercase().as_str()))
}

/// Caption first (the instruction), then the escaped paths, so "fix this"
/// lands ahead of the file the agent should open.
pub fn compose_order_text(paths: &[String], caption: Option<&str>) -> String {
    let note = caption.map(str::trim).unwrap_or_default();
    let path_line = paths.iter().map(|p| shell_escape(p)).collect::<Vec<_>>().join(" ");
    match (path_line.is_empty(), note.is_empty()) {
        (true, true) => String::new(),
        (true, false) => note.to_string(),
        (false, true) => path_line,
        (false, false) => format!("{note}\n{path_line}"),
    }
}

/// A file name from a document's name or Telegram's path.
pub fn file_name(telegram_path: Option<&str>, document_name: Option<&str>) -> String {
    let base = |p: &str| p.rsplit('/').next().unwrap_or(p).to_string();
    if let Some(n) = document_name.filter(|n| !n.is_empty()) {
        return sanitized_file_name(&base(n));
    }
    if let Some(p) = telegram_path.filter(|p| !p.is_empty()) {
        return sanitized_file_name(&base(p));
    }
    "image.jpg".into()
}

pub fn sanitized_file_name(name: &str) -> String {
    let base = name.rsplit('/').next().unwrap_or(name);
    let cleaned: String = base.chars().map(|c| if c == ':' || c == '\\' || c.is_control() { '_' } else { c }).collect();
    let cleaned = cleaned.trim();
    if cleaned.is_empty() || cleaned == "." || cleaned == ".." {
        "image.jpg".into()
    } else {
        cleaned.to_string()
    }
}

/// Backslash escapes, the way a terminal drop types a path.
pub fn shell_escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        if "\\ ()[]{}<>\"'`!#$&;|*?\t".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::telegram::api::{Chat, ReplyTarget, User};

    pub fn user(id: i64, name: Option<&str>) -> User {
        User { id, is_bot: None, first_name: None, username: name.map(str::to_string) }
    }

    pub fn msg(chat_id: i64, kind: &str, from: Option<User>, text: &str) -> Message {
        Message {
            message_id: 1,
            date: 0.0,
            chat: Chat { id: chat_id, kind: kind.into(), title: None, username: None },
            from,
            sender_chat: None,
            text: Some(text.into()),
            caption: None,
            photo: None,
            document: None,
            reply_to_message: None,
        }
    }

    fn cfg() -> TelegramConfig {
        TelegramConfig { allowed_users: vec!["@me".into(), "42".into()], ..TelegramConfig::default() }
    }

    const BOT: Option<&str> = Some("helm_bot");

    #[test]
    fn private_prose_from_an_allowed_user_is_an_order() {
        let m = msg(7, "private", Some(user(7, Some("Me"))), "fix the tests");
        assert_eq!(order(&m, "fix the tests", &cfg(), BOT).unwrap().body, "fix the tests");
        let stranger = msg(9, "private", Some(user(9, Some("x"))), "hi");
        assert!(order(&stranger, "hi", &cfg(), BOT).is_none());
        let channel = msg(-100, "channel", None, "/status");
        assert!(order(&channel, "/status", &cfg(), BOT).is_none());
    }

    #[test]
    fn group_lines_must_be_addressed() {
        let c = cfg();
        let g = |t: &str| msg(-5, "supergroup", Some(user(42, None)), t);
        assert_eq!(order(&g("/status@helm_bot"), "/status@helm_bot", &c, BOT).unwrap().body, "/status");
        assert_eq!(order(&g("@Helm_Bot run it"), "@Helm_Bot run it", &c, BOT).unwrap().body, "run it");
        assert!(order(&g("@helm_bot"), "@helm_bot", &c, BOT).is_none());
        assert!(order(&g("just talking"), "just talking", &c, BOT).is_none());
        assert!(is_unaddressed_order(&g("just talking"), &c, BOT));
        assert!(!is_unaddressed_order(&g("/go #3"), &c, BOT));
        let mut reply = g("yes do that");
        reply.reply_to_message = Some(ReplyTarget { message_id: 3, from: Some(user(1, Some("helm_bot"))) });
        assert_eq!(order(&reply, "yes do that", &c, BOT).unwrap().body, "yes do that");
        let mut to_other = g("yes");
        to_other.reply_to_message = Some(ReplyTarget { message_id: 3, from: Some(user(2, Some("bob"))) });
        assert!(order(&to_other, "yes", &c, BOT).is_none());
        // Someone off the list in a group is never an unaddressed order.
        assert!(!is_unaddressed_order(&msg(-5, "group", Some(user(9, None)), "hello"), &c, BOT));
    }

    #[test]
    fn slash_commands_and_mentions() {
        assert!(is_slash_command("/go #3"));
        assert!(is_slash_command("/status@bot"));
        assert!(is_slash_command("/"));
        assert!(!is_slash_command("/usr/bin/env"));
        assert!(!is_slash_command("hello"));
        assert_eq!(strip_bot_mention("/start@HELM_bot ABC", BOT), "/start ABC");
        assert_eq!(strip_bot_mention("/start@other_bot", BOT), "/start@other_bot");
        assert_eq!(start_payload("/start"), Some(String::new()));
        assert_eq!(start_payload(" /start  AB12CD34 "), Some("AB12CD34".into()));
        assert_eq!(start_payload("/started"), None);
    }

    #[test]
    fn signal_senders() {
        assert_eq!(signal_sender(&msg(1, "group", Some(user(5, Some("al"))), "x")), "@al");
        assert_eq!(signal_sender(&msg(1, "group", Some(user(5, None)), "x")), "5");
        let mut post = msg(-100, "channel", None, "x");
        post.chat.title = Some("Alerts".into());
        assert_eq!(signal_sender(&post), "Alerts");
    }

    #[test]
    fn media_order_text() {
        let paths = vec!["/tmp/a b/shot (1).png".to_string()];
        assert_eq!(compose_order_text(&paths, Some(" fix this ")), "fix this\n/tmp/a\\ b/shot\\ \\(1\\).png");
        assert_eq!(compose_order_text(&paths, None), "/tmp/a\\ b/shot\\ \\(1\\).png");
        assert_eq!(compose_order_text(&[], Some("x")), "x");
        assert_eq!(compose_order_text(&[], Some("  ")), "");
        assert_eq!(file_name(Some("photos/file_0.jpg"), None), "file_0.jpg");
        assert_eq!(file_name(None, Some("../evil:name.png")), "evil_name.png");
        assert_eq!(file_name(None, None), "image.jpg");
        let doc = |m: Option<&str>, n: Option<&str>| Document { file_id: "f".into(), file_name: n.map(Into::into), mime_type: m.map(Into::into), file_size: None };
        assert!(is_image_document(&doc(Some("image/png"), None)));
        assert!(is_image_document(&doc(None, Some("x.HEIC"))));
        assert!(!is_image_document(&doc(Some("application/pdf"), Some("x.pdf"))));
        let sizes = vec![
            PhotoSize { file_id: "s".into(), width: 90, height: 90, file_size: Some(1000) },
            PhotoSize { file_id: "l".into(), width: 800, height: 800, file_size: Some(90000) },
        ];
        assert_eq!(preferred_photo(&sizes).unwrap().file_id, "l");
    }
}
