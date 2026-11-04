//! The Bot API methods the adapter uses, over one pooled reqwest client
//! (rustls). Every method answers `{ok, result}` or `{ok: false, error_code,
//! description}`; `call` is the one place that shape is known. The token is
//! in the URL and so never leaves this process, and no error that reaches a
//! log carries it.

use std::time::Duration;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer};
use serde_json::{json, Value};

use super::format;

pub const HOST: &str = "https://api.telegram.org";
/// How long `getUpdates` holds the request open; Telegram answers the moment
/// something arrives, and closes it itself when this runs out.
pub const LONG_POLL_SECONDS: u64 = 50;
/// Slack past the long poll before a call is abandoned; short calls get this
/// alone.
pub const STALL_SECONDS: u64 = 15;
/// Bot API downloads top out at 20 MB; refuse anything larger here too.
pub const MAX_FILE_BYTES: usize = 20 * 1024 * 1024;

// MARK: wire types

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct User {
    pub id: i64,
    #[serde(default)]
    pub is_bot: Option<bool>,
    #[serde(default)]
    pub first_name: Option<String>,
    #[serde(default)]
    pub username: Option<String>,
}

impl User {
    /// What a log line or a reply calls this person.
    pub fn display_name(&self) -> String {
        if let Some(u) = self.username.as_deref().filter(|u| !u.is_empty()) {
            return format!("@{u}");
        }
        if let Some(f) = self.first_name.as_deref().filter(|f| !f.is_empty()) {
            return f.to_string();
        }
        self.id.to_string()
    }

    /// `_meta.via` for calls made on this person's behalf.
    pub fn via(&self) -> String {
        match self.username.as_deref().filter(|u| !u.is_empty()) {
            Some(u) => format!("telegram:@{u}"),
            None => format!("telegram:{}", self.id),
        }
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Chat {
    pub id: i64,
    /// `private`, `group`, `supergroup` or `channel`.
    #[serde(rename = "type", default)]
    pub kind: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub username: Option<String>,
}

impl Chat {
    pub fn is_private(&self) -> bool {
        self.kind == "private"
    }
}

/// The one question asked of a message being replied to: who sent it.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct ReplyTarget {
    pub message_id: i64,
    #[serde(default)]
    pub from: Option<User>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct PhotoSize {
    pub file_id: String,
    #[serde(default)]
    pub width: i64,
    #[serde(default)]
    pub height: i64,
    #[serde(default)]
    pub file_size: Option<i64>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Document {
    pub file_id: String,
    #[serde(default)]
    pub file_name: Option<String>,
    #[serde(default)]
    pub mime_type: Option<String>,
    #[serde(default)]
    pub file_size: Option<i64>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct File {
    pub file_id: String,
    #[serde(default)]
    pub file_size: Option<i64>,
    #[serde(default)]
    pub file_path: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Message {
    pub message_id: i64,
    /// Unix seconds (0 for a message Telegram no longer shows the bot).
    #[serde(default)]
    pub date: f64,
    pub chat: Chat,
    /// Absent for channel posts and for admins posting anonymously.
    #[serde(default)]
    pub from: Option<User>,
    #[serde(default)]
    pub sender_chat: Option<Chat>,
    #[serde(default)]
    pub text: Option<String>,
    /// A photo or document's note comes here, not in `text`.
    #[serde(default)]
    pub caption: Option<String>,
    #[serde(default)]
    pub photo: Option<Vec<PhotoSize>>,
    #[serde(default)]
    pub document: Option<Document>,
    #[serde(default)]
    pub reply_to_message: Option<ReplyTarget>,
}

impl Message {
    pub fn body(&self) -> Option<&str> {
        self.text.as_deref().or(self.caption.as_deref())
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct CallbackQuery {
    pub id: String,
    pub from: User,
    #[serde(default)]
    pub message: Option<Message>,
    #[serde(default)]
    pub data: Option<String>,
}

/// Stop was pressed under a streamed draft. `draft_id` is documented as an
/// integer and arrives as a string (`"62"`, seen live), so either is read.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GenerationStopped {
    pub chat: Chat,
    #[serde(deserialize_with = "number_or_string")]
    pub draft_id: i64,
}

fn number_or_string<'de, D: Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
    match Value::deserialize(d)? {
        Value::Number(n) => n.as_i64().ok_or_else(|| serde::de::Error::custom("draft_id out of range")),
        Value::String(s) => s.trim().parse().map_err(|_| serde::de::Error::custom("draft_id is not numeric")),
        _ => Err(serde::de::Error::custom("draft_id is neither a number nor a numeric string")),
    }
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
pub struct Update {
    pub update_id: i64,
    #[serde(default)]
    pub message: Option<Message>,
    #[serde(default)]
    pub channel_post: Option<Message>,
    #[serde(default)]
    pub callback_query: Option<CallbackQuery>,
    #[serde(default)]
    pub stopped_message_generation: Option<GenerationStopped>,
}

impl Update {
    /// The one kind of message the adapter acts on; edits and reactions are
    /// not asked for (`allowed_updates`), so they never arrive.
    pub fn payload(&self) -> Option<&Message> {
        self.message.as_ref().or(self.channel_post.as_ref())
    }
}

/// An update whose body does not decode still has an id, and the id must
/// still advance the offset: otherwise one odd payload would be fetched
/// forever and wedge the poll on it.
pub fn decode_updates(result: Vec<Value>) -> Vec<Update> {
    result
        .into_iter()
        .filter_map(|v| match serde_json::from_value::<Update>(v.clone()) {
            Ok(u) => Some(u),
            Err(_) => v.get("update_id").and_then(Value::as_i64).map(|update_id| Update { update_id, ..Update::default() }),
        })
        .collect()
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct BotInfo {
    pub id: i64,
    #[serde(default)]
    pub username: Option<String>,
}

/// A button: what it says, and the token it carries back when tapped.
#[derive(Debug, Clone, PartialEq)]
pub struct Button {
    pub label: String,
    pub token: String,
}

/// One button per row: an option is a sentence, and Telegram truncates a row
/// it cannot fit rather than wrapping it.
pub fn keyboard(buttons: &[Button]) -> Value {
    Value::Array(buttons.iter().map(|b| json!([{"text": format::trim_label(&b.label, 48), "callback_data": b.token}])).collect())
}

// MARK: errors

#[derive(Debug, Clone, PartialEq)]
pub enum ApiError {
    /// DNS, TLS, timeout, no route.
    Network(String),
    /// Telegram answered, but not with the envelope.
    BadResponse,
    /// Telegram said no.
    Api { code: i64, description: String },
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ApiError::Network(m) => write!(f, "Could not reach Telegram: {m}"),
            ApiError::BadResponse => write!(f, "Telegram returned an unexpected response"),
            ApiError::Api { code: code @ (401 | 404), description } => write!(f, "Telegram rejected the bot token ({code} {description})"),
            ApiError::Api { code: 409, description } => {
                write!(f, "Another client is already polling this bot: a webhook is set, or a second gateway is running ({description})")
            }
            ApiError::Api { code, description } => write!(f, "Telegram error {code}: {description}"),
        }
    }
}

impl ApiError {
    /// Retrying cannot help: the token is wrong. A 409 (another poller) is
    /// not here; it is usually a previous instance still shutting down.
    pub fn is_fatal(&self) -> bool {
        matches!(self, ApiError::Api { code: 401 | 404, .. })
    }

    /// The chat cannot be written to and will not come back on its own (bot
    /// removed or blocked, chat deleted): every 403 for a send, and "chat not
    /// found", which arrives as a 400.
    pub fn is_chat_gone(&self) -> bool {
        match self {
            ApiError::Api { code: 403, .. } => true,
            ApiError::Api { code: 400, description } => description.to_lowercase().contains("chat not found"),
            _ => false,
        }
    }

    pub fn is_bad_request(&self) -> bool {
        matches!(self, ApiError::Api { code: 400, .. })
    }

    /// "That edit would change nothing": the API agreeing with us.
    pub fn is_not_modified(&self) -> bool {
        matches!(self, ApiError::Api { code: 400, description } if description.contains("message is not modified"))
    }
}

// MARK: client

/// One bot, over the shared HTTP client.
#[derive(Clone)]
pub struct Bot {
    http: reqwest::Client,
    token: String,
}

/// The shared client: connections to Telegram are reused, so a reply does not
/// pay a fresh TLS handshake.
pub fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .use_rustls_tls()
        .pool_idle_timeout(Duration::from_secs(90))
        .connect_timeout(Duration::from_secs(10))
        .build()
        .unwrap_or_default()
}

impl Bot {
    pub fn new(http: reqwest::Client, token: impl Into<String>) -> Bot {
        Bot { http, token: token.into() }
    }

    fn scrub(&self, message: &str) -> String {
        if self.token.is_empty() {
            message.to_string()
        } else {
            message.replace(&self.token, "<token>")
        }
    }

    pub async fn call<T: DeserializeOwned>(&self, method: &str, params: Value, timeout_secs: u64) -> Result<T, ApiError> {
        let url = format!("{HOST}/bot{}/{method}", self.token);
        let response = self
            .http
            .post(url)
            .timeout(Duration::from_secs(timeout_secs))
            .json(&params)
            .send()
            .await
            .map_err(|e| ApiError::Network(self.scrub(&describe(e))))?;
        // Not judged on the status: a 4xx carries the envelope, and its
        // description is the useful part.
        let body = response.bytes().await.map_err(|e| ApiError::Network(self.scrub(&describe(e))))?;
        let envelope: Value = serde_json::from_slice(&body).map_err(|_| ApiError::BadResponse)?;
        if envelope.get("ok").and_then(Value::as_bool) != Some(true) {
            return Err(ApiError::Api {
                code: envelope.get("error_code").and_then(Value::as_i64).unwrap_or(0),
                description: self.scrub(envelope.get("description").and_then(Value::as_str).unwrap_or("unknown error")),
            });
        }
        serde_json::from_value(envelope.get("result").cloned().unwrap_or(Value::Null)).map_err(|_| ApiError::BadResponse)
    }

    pub async fn get_me(&self) -> Result<BotInfo, ApiError> {
        self.call("getMe", json!({}), STALL_SECONDS).await
    }

    pub async fn get_updates(&self, offset: Option<i64>, timeout: u64) -> Result<Vec<Update>, ApiError> {
        let mut params = json!({
            "timeout": timeout,
            "limit": 100,
            // Only what the adapter acts on. A button tap is a
            // `callback_query` and arrives nowhere else; a draft's Stop is
            // `stopped_message_generation`, which Telegram drops outright
            // unless it is asked for.
            "allowed_updates": ["message", "channel_post", "callback_query", "stopped_message_generation"],
        });
        if let Some(o) = offset {
            params["offset"] = json!(o);
        }
        let raw: Vec<Value> = self.call("getUpdates", params, timeout + STALL_SECONDS).await?;
        Ok(decode_updates(raw))
    }

    /// One message; callers chunk first. Returns its id.
    pub async fn send_message(&self, chat_id: &str, text: &str, html: bool, buttons: &[Button]) -> Result<i64, ApiError> {
        let mut params = json!({
            "chat_id": chat_id,
            "text": text,
            // Agent output is full of paths and URLs; a preview under each is noise.
            "link_preview_options": {"is_disabled": true},
        });
        if html {
            params["parse_mode"] = json!("HTML");
        }
        if !buttons.is_empty() {
            params["reply_markup"] = json!({"inline_keyboard": keyboard(buttons)});
        }
        let sent: Message = self.call("sendMessage", params, STALL_SECONDS).await?;
        Ok(sent.message_id)
    }

    /// Stream a partial message into a private chat: Telegram's typing
    /// preview, animated in place while `draft_id` stays the same. Private
    /// chats only (a group answers `TEXTDRAFT_PEER_INVALID`), one per chat (a
    /// different id replaces it), and it fades about 12 s after the last call
    /// (the docs say 30) and the moment the bot sends anything else there.
    pub async fn send_message_draft(&self, chat_id: &str, draft_id: i64, text: &str, html: bool, can_stop: bool) -> Result<(), ApiError> {
        let mut params = json!({"chat_id": chat_id, "draft_id": draft_id, "text": text});
        if html {
            params["parse_mode"] = json!("HTML");
        }
        if can_stop {
            params["can_stop"] = json!(true);
        }
        let _: Value = self.call("sendMessageDraft", params, STALL_SECONDS).await?;
        Ok(())
    }

    pub async fn answer_callback_query(&self, id: &str, text: Option<&str>) -> Result<(), ApiError> {
        let mut params = json!({"callback_query_id": id});
        if let Some(t) = text.filter(|t| !t.is_empty()) {
            params["text"] = json!(t.chars().take(200).collect::<String>());
        }
        let _: Value = self.call("answerCallbackQuery", params, STALL_SECONDS).await?;
        Ok(())
    }

    /// Put a keyboard on a message already sent, or take it off with `[]`.
    pub async fn set_reply_markup(&self, chat_id: &str, message_id: i64, buttons: &[Button]) -> Result<(), ApiError> {
        let mut params = json!({"chat_id": chat_id, "message_id": message_id});
        if !buttons.is_empty() {
            params["reply_markup"] = json!({"inline_keyboard": keyboard(buttons)});
        }
        let _: Value = self.call("editMessageReplyMarkup", params, STALL_SECONDS).await?;
        Ok(())
    }

    pub async fn edit_message_text(&self, chat_id: &str, message_id: i64, text: &str, html: bool) -> Result<(), ApiError> {
        let mut params = json!({"chat_id": chat_id, "message_id": message_id, "text": text});
        if html {
            params["parse_mode"] = json!("HTML");
        }
        let _: Value = self.call("editMessageText", params, STALL_SECONDS).await?;
        Ok(())
    }

    pub async fn delete_message(&self, chat_id: &str, message_id: i64) -> Result<(), ApiError> {
        let _: Value = self.call("deleteMessage", json!({"chat_id": chat_id, "message_id": message_id}), STALL_SECONDS).await?;
        Ok(())
    }

    pub async fn set_my_commands(&self, commands: &[(&str, &str)]) -> Result<(), ApiError> {
        let list: Vec<Value> = commands.iter().map(|(c, d)| json!({"command": c, "description": d})).collect();
        let _: Value = self.call("setMyCommands", json!({"commands": list}), STALL_SECONDS).await?;
        Ok(())
    }

    /// Point the bot's menu button at the Mini App, or put the default back.
    pub async fn set_menu_button(&self, web_app: Option<&str>) -> Result<(), ApiError> {
        let button = match web_app {
            Some(url) => json!({"type": "web_app", "text": "Seahelm", "web_app": {"url": url}}),
            None => json!({"type": "default"}),
        };
        let _: Value = self.call("setChatMenuButton", json!({"menu_button": button}), STALL_SECONDS).await?;
        Ok(())
    }

    pub async fn get_file(&self, file_id: &str) -> Result<File, ApiError> {
        self.call("getFile", json!({"file_id": file_id}), STALL_SECONDS).await
    }

    /// The bytes at a `getFile` path, at most `MAX_FILE_BYTES`.
    pub async fn download_file(&self, file_path: &str) -> Result<Vec<u8>, ApiError> {
        // Telegram's paths are relative (`photos/file_0.jpg`); refuse anything
        // that could leave the file host's prefix.
        if file_path.starts_with('/') || file_path.contains("..") || file_path.contains("://") {
            return Err(ApiError::BadResponse);
        }
        let url = format!("{HOST}/file/bot{}/{file_path}", self.token);
        let mut response = self
            .http
            .get(url)
            .timeout(Duration::from_secs(STALL_SECONDS * 4))
            .send()
            .await
            .map_err(|e| ApiError::Network(self.scrub(&describe(e))))?;
        // A stale path answers with a JSON error, not bytes.
        if response.status() != reqwest::StatusCode::OK {
            return Err(ApiError::BadResponse);
        }
        let mut data = Vec::new();
        while let Some(piece) = response.chunk().await.map_err(|e| ApiError::Network(self.scrub(&describe(e))))? {
            if data.len() + piece.len() > MAX_FILE_BYTES {
                return Err(ApiError::Network(format!("file exceeds {MAX_FILE_BYTES} bytes")));
            }
            data.extend_from_slice(&piece);
        }
        if data.is_empty() {
            return Err(ApiError::BadResponse);
        }
        Ok(data)
    }
}

/// A reqwest error in words, without the URL (which carries the token).
fn describe(e: reqwest::Error) -> String {
    if e.is_timeout() {
        return "no response in time".into();
    }
    e.without_url().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_updates_leniently() {
        let raw = vec![
            json!({"update_id": 1, "message": {"message_id": 5, "date": 100, "chat": {"id": 7, "type": "private"}, "from": {"id": 7, "username": "me"}, "text": "hi"}}),
            json!({"update_id": 2, "message": {"message_id": "not a number"}}),
            json!({"update_id": 3, "stopped_message_generation": {"chat": {"id": 7, "type": "private"}, "draft_id": "62"}}),
            json!({"no_id": true}),
        ];
        let ups = decode_updates(raw);
        assert_eq!(ups.len(), 3);
        assert_eq!(ups[0].payload().unwrap().body(), Some("hi"));
        assert_eq!(ups[1].update_id, 2);
        assert!(ups[1].payload().is_none());
        assert_eq!(ups[2].stopped_message_generation.as_ref().unwrap().draft_id, 62);
    }

    #[test]
    fn classifies_errors() {
        let e = |code, d: &str| ApiError::Api { code, description: d.into() };
        assert!(e(401, "Unauthorized").is_fatal());
        assert!(!e(409, "Conflict").is_fatal());
        assert!(e(403, "bot was blocked by the user").is_chat_gone());
        assert!(e(400, "Bad Request: chat not found").is_chat_gone());
        assert!(!e(400, "Bad Request: can't parse entities").is_chat_gone());
        assert!(e(400, "Bad Request: message is not modified").is_not_modified());
    }

    #[test]
    fn keyboard_is_one_button_per_row() {
        let k = keyboard(&[Button { label: "Yes\nplease".into(), token: "a".into() }, Button { label: "No".into(), token: "b".into() }]);
        assert_eq!(k, json!([[{"text": "Yes please", "callback_data": "a"}], [{"text": "No", "callback_data": "b"}]]));
    }

    #[test]
    fn names_people() {
        let u = User { id: 5, is_bot: None, first_name: Some("Ann".into()), username: None };
        assert_eq!(u.display_name(), "Ann");
        assert_eq!(u.via(), "telegram:5");
        let u = User { username: Some("ann".into()), ..u };
        assert_eq!(u.display_name(), "@ann");
        assert_eq!(u.via(), "telegram:@ann");
    }
}
