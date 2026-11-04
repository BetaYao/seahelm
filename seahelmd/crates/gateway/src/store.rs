//! The gateway's own files (docs/seahelm-gateway-plan.md): `config.json`
//! (settings), `secrets.json` (root secret, pairing code, bot token) and
//! `state.json` (devices, share links, chat bindings), all owner-only. On the
//! first start they are imported from what the macOS app used to keep.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct WebConfig {
    pub enabled: bool,
    pub port: u16,
    /// What links and the pairing page point at (`https://gw.example.dev`).
    /// Empty: `http://<lan address>:<port>`.
    pub public_url: Option<String>,
    /// A working copy of seahelm-web to serve instead of the bundled one.
    pub web_root: Option<String>,
    /// The Mini App host, where the pairing code is refused. Empty: the host
    /// of `telegram.mini_app_url`.
    pub telegram_host: Option<String>,
}

impl Default for WebConfig {
    fn default() -> Self {
        Self { enabled: false, port: 2783, public_url: None, web_root: None, telegram_host: None }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct TelegramConfig {
    pub enabled: bool,
    /// Numeric ids or `@usernames`. Empty obeys nobody.
    pub allowed_users: Vec<String>,
    pub default_chat_id: Option<String>,
    pub backfill_seconds: f64,
    /// `TelegramRule`s, as the rules editor writes them.
    pub rules: Vec<Value>,
    pub mini_app_url: Option<String>,
}

impl Default for TelegramConfig {
    fn default() -> Self {
        Self { enabled: true, allowed_users: Vec::new(), default_chat_id: None, backfill_seconds: 60.0, rules: Vec::new(), mini_app_url: None }
    }
}

impl TelegramConfig {
    /// Whether this Telegram user may give orders. Usernames compare without
    /// case and without the `@`.
    pub fn allows(&self, user_id: i64, username: Option<&str>) -> bool {
        let id = user_id.to_string();
        let name = username.map(normalize_user).unwrap_or_default();
        self.allowed_users.iter().any(|entry| {
            let needle = normalize_user(entry);
            !needle.is_empty() && (needle == id || (!name.is_empty() && needle == name))
        })
    }

    /// The Mini App URL when it is a usable https URL.
    pub fn mini_app_url(&self) -> Option<String> {
        let t = self.mini_app_url.as_deref()?.trim();
        (t.to_ascii_lowercase().starts_with("https://") && url_host(t).is_some()).then(|| t.to_string())
    }
}

fn normalize_user(entry: &str) -> String {
    entry.trim().trim_start_matches('@').to_ascii_lowercase()
}

/// The host of an `http(s)://host[:port]/…` URL, lowercased.
pub fn url_host(url: &str) -> Option<String> {
    let rest = url.split_once("://")?.1;
    let authority = rest.split(['/', '?', '#']).next()?;
    let authority = authority.rsplit('@').next()?;
    let host = if authority.starts_with('[') { authority.split(']').next().map(|h| format!("{h}]"))? } else { authority.split(':').next()?.to_string() };
    (!host.is_empty()).then(|| host.to_ascii_lowercase())
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Config {
    pub web: WebConfig,
    pub telegram: TelegramConfig,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Secrets {
    /// base64url, 32 bytes. Derives the legacy token; rotated by revoke-all.
    pub root_secret: String,
    pub mac_id: String,
    pub pair_code: Option<String>,
    pub telegram_bot_token: Option<String>,
}

/// A browser or Mini App that signed in and holds a device token.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Device {
    pub id: String,
    pub label: String,
    /// `code`, `telegram` or `legacy`: how it first signed in.
    pub via: String,
    pub token_hash: String,
    pub created_at: f64,
    pub last_seen_at: f64,
}

/// One link that opens one pane. Only the token's hash is kept.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ShareLink {
    pub id: String,
    pub pane_session_key: String,
    #[serde(default)]
    pub label: String,
    pub token_hash: String,
    pub created_at: f64,
    #[serde(default)]
    pub expires_at: Option<f64>,
    /// Set: every message sent through the link is signed with this name.
    #[serde(default)]
    pub recipient: Option<String>,
}

impl ShareLink {
    pub fn is_live(&self, now: f64) -> bool {
        self.expires_at.is_none_or(|e| e > now)
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct State {
    pub devices: Vec<Device>,
    pub share_links: Vec<ShareLink>,
    /// Chat key (`telegram:<chat id>`) → what that chat talks to. The
    /// Telegram adapter's to read and write.
    pub chat_sessions: Map<String, Value>,
}

/// All three files, loaded. Callers hold it behind a lock and save the part
/// they changed.
pub struct Store {
    dir: PathBuf,
    pub config: Config,
    pub secrets: Secrets,
    pub state: State,
}

impl Store {
    /// Load from `dir`, importing from the app's files on the first start.
    pub fn open(dir: &Path) -> Result<Store> {
        create_private_dir(dir)?;
        let config_path = dir.join("config.json");
        if !config_path.exists() {
            let imported = import(&crate::paths::config_dir());
            let mut store = Store { dir: dir.to_path_buf(), config: imported.0, secrets: imported.1, state: imported.2 };
            store.fill_secrets();
            store.save_state()?;
            store.save_secrets()?;
            // Last: its presence is what says the import is done.
            store.save_config()?;
            eprintln!("seahelm-gateway: imported settings into {}", dir.display());
            return Ok(store);
        }
        let mut store = Store {
            dir: dir.to_path_buf(),
            config: read_json(&config_path).unwrap_or_default(),
            secrets: read_json(&dir.join("secrets.json")).unwrap_or_default(),
            state: read_json(&dir.join("state.json")).unwrap_or_default(),
        };
        if store.fill_secrets() {
            store.save_secrets()?;
        }
        Ok(store)
    }

    /// Mint what is missing. True when something was.
    fn fill_secrets(&mut self) -> bool {
        let mut changed = false;
        if crate::auth::root_secret_bytes(&self.secrets.root_secret).is_none() {
            self.secrets.root_secret = crate::auth::new_root_secret();
            changed = true;
        }
        if self.secrets.mac_id.is_empty() {
            self.secrets.mac_id = derive_mac_id();
            changed = true;
        }
        if !self.secrets.pair_code.as_deref().is_some_and(crate::auth::is_valid_code) {
            self.secrets.pair_code = Some(crate::auth::generate_code());
            changed = true;
        }
        changed
    }

    pub fn save_config(&self) -> Result<()> {
        write_json(&self.dir.join("config.json"), &self.config)
    }

    pub fn save_secrets(&self) -> Result<()> {
        write_json(&self.dir.join("secrets.json"), &self.secrets)
    }

    pub fn save_state(&self) -> Result<()> {
        write_json(&self.dir.join("state.json"), &self.state)
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn bot_token(&self) -> Option<String> {
        self.secrets.telegram_bot_token.as_deref().map(str::trim).filter(|t| !t.is_empty()).map(str::to_string)
    }

    /// The Mini App host: the configured one, else `mini_app_url`'s.
    pub fn telegram_host(&self) -> Option<String> {
        if let Some(h) = self.config.web.telegram_host.as_deref().map(|h| h.trim().to_ascii_lowercase()).filter(|h| !h.is_empty()) {
            return Some(h);
        }
        self.config.telegram.mini_app_url().and_then(|u| url_host(&u))
    }
}

/// What the app kept, in the gateway's shape: config, secrets, state.
fn import(app_dir: &Path) -> (Config, Secrets, State) {
    // The app keeps the file as it was before its first save without these
    // keys (`Config.keepPreGatewayCopy`); that copy wins when it exists.
    let app: Value = read_json(&app_dir.join("config.pre-gateway.json"))
        .or_else(|| read_json(&app_dir.join("config.json")))
        .unwrap_or(Value::Null);
    let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).map(str::to_string).filter(|t| !t.trim().is_empty());
    let hg = app.get("host_gateway").cloned().unwrap_or(Value::Null);
    let tg = app.get("telegram").cloned().unwrap_or(Value::Null);
    let pairing = app.get("mqtt").cloned().unwrap_or(Value::Null);

    let mut config = Config::default();
    config.web.enabled = hg.get("enabled").and_then(Value::as_bool).unwrap_or(false);
    if let Some(port) = hg.get("port").and_then(Value::as_u64).filter(|p| *p > 0 && *p <= u16::MAX as u64) {
        config.web.port = port as u16;
    }
    config.web.public_url = s(&hg, "public_url");
    config.web.web_root = s(&hg, "web_root");
    config.web.telegram_host = s(&hg, "telegram_host");
    config.telegram.enabled = tg.get("auto_connect").and_then(Value::as_bool).unwrap_or(true);
    config.telegram.allowed_users =
        tg.get("allowed_users").and_then(Value::as_array).map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default();
    config.telegram.default_chat_id = s(&tg, "default_chat_id");
    if let Some(b) = tg.get("backfill_seconds").and_then(Value::as_f64) {
        config.telegram.backfill_seconds = b;
    }
    config.telegram.rules = tg.get("rules").and_then(Value::as_array).cloned().unwrap_or_default();
    config.telegram.mini_app_url = s(&tg, "mini_app_url");

    let secrets = Secrets {
        root_secret: s(&pairing, "root_secret").unwrap_or_default(),
        mac_id: s(&pairing, "mac_id").unwrap_or_default(),
        pair_code: s(&hg, "pair_code"),
        telegram_bot_token: s(&tg, "bot_token"),
    };

    let mut state = State::default();
    if let Some(links) = read_json::<Vec<ShareLink>>(&app_dir.join("share-links.json")) {
        state.share_links = links;
    }
    if let Some(Value::Object(sessions)) = read_json::<Value>(&app_dir.join("command-sessions.json")) {
        for (k, v) in sessions {
            if k.starts_with("telegram:") && !k.contains('#') {
                state.chat_sessions.insert(k, v);
            }
        }
    }
    (config, secrets, state)
}

/// A stable, non-PII id from the host name (djb2-ish), as the app derived it.
pub fn derive_mac_id() -> String {
    let name = host_name();
    let mut h: u64 = 5381;
    for b in name.bytes() {
        h = h.wrapping_mul(33) ^ b as u64;
    }
    format!("m{:x}", h & 0xFFFF_FFFF)
}

fn host_name() -> String {
    #[cfg(unix)]
    {
        let mut buf = [0u8; 256];
        // SAFETY: the buffer outlives the call and its length is passed.
        if unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0 {
            let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
            return String::from_utf8_lossy(&buf[..end]).into_owned();
        }
    }
    std::env::var("COMPUTERNAME").unwrap_or_else(|_| "seahelm".into())
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Option<T> {
    let data = std::fs::read(path).ok()?;
    serde_json::from_slice(&data).ok()
}

/// Write to a temp file beside it, owner-only, then rename over.
fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let data = serde_json::to_vec_pretty(value)?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, &data).with_context(|| format!("write {}", tmp.display()))?;
    set_private(&tmp, 0o600);
    std::fs::rename(&tmp, path).with_context(|| format!("rename to {}", path.display()))?;
    Ok(())
}

fn create_private_dir(dir: &Path) -> Result<()> {
    std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    set_private(dir, 0o700);
    Ok(())
}

#[allow(unused_variables)]
fn set_private(path: &Path, mode: u32) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn imports_the_apps_settings_once() {
        let home = tempfile::tempdir().unwrap();
        let app = home.path().join("app");
        std::fs::create_dir_all(&app).unwrap();
        std::fs::write(
            app.join("config.json"),
            json!({
                "mqtt": {"root_secret": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", "mac_id": "m1"},
                "host_gateway": {"enabled": true, "port": 9000, "public_url": "https://gw.x", "pair_code": "12345678", "telegram_host": "tg.x"},
                "telegram": {"bot_token": "1:abc", "allowed_users": ["@me"], "auto_connect": false, "mini_app_url": "https://tg.x/"},
                "workspace_paths": []
            })
            .to_string(),
        )
        .unwrap();
        std::fs::write(app.join("share-links.json"), json!([{"id": "l1", "pane_session_key": "p", "label": "x", "token_hash": "h", "created_at": 1.0}]).to_string()).unwrap();
        std::fs::write(app.join("command-sessions.json"), json!({"telegram:5": {"key": "telegram:5"}, "telegram:5#2": {}, "mail:x": {}}).to_string()).unwrap();
        let (c, s, st) = import(&app);
        assert!(c.web.enabled);
        assert_eq!(c.web.port, 9000);
        assert!(!c.telegram.enabled);
        assert_eq!(s.root_secret, "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8");
        assert_eq!(s.pair_code.as_deref(), Some("12345678"));
        assert_eq!(s.telegram_bot_token.as_deref(), Some("1:abc"));
        assert_eq!(st.share_links.len(), 1);
        assert_eq!(st.chat_sessions.keys().collect::<Vec<_>>(), vec!["telegram:5"]);
        assert!(c.telegram.allows(1, Some("ME")));
    }

    #[test]
    fn url_hosts() {
        assert_eq!(url_host("https://TG.seahelm.dev/app?x").as_deref(), Some("tg.seahelm.dev"));
        assert_eq!(url_host("http://h:80").as_deref(), Some("h"));
        assert_eq!(url_host("nope"), None);
    }
}
