//! seahelm-gateway's admin socket (`gateway.sock`, a named pipe on Windows;
//! docs/seahelm-gateway-plan.md "gateway.sock"): what the Settings ▸ Telegram and ▸ Pairing pages
//! reads and the changes it makes. Blocking calls; run them off the UI thread.

use serde::Deserialize;
use serde_json::{json, Value};

fn call(method: &str, params: Value) -> Result<Value, String> {
    crate::core_client::call_at(&crate::platform::gateway_socket(), method, params)
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct WebStatus {
    pub enabled: bool,
    pub listening: bool,
    pub port: u16,
    pub public_url: Option<String>,
    pub error: Option<String>,
    pub clients: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct TelegramStatus {
    pub enabled: bool,
    pub configured: bool,
    pub connected: bool,
    pub bot_username: Option<String>,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct CoreStatus {
    pub reachable: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Status {
    pub web: WebStatus,
    pub telegram: TelegramStatus,
    pub core: CoreStatus,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct WebConfig {
    pub enabled: bool,
    pub port: u16,
    pub public_url: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct TelegramConfig {
    pub enabled: bool,
    pub bot_token_set: bool,
    pub allowed_users: Vec<String>,
    pub default_chat_id: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Config {
    pub web: WebConfig,
    pub telegram: TelegramConfig,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Device {
    pub id: String,
    pub label: String,
    pub via: String,
    pub created_at: f64,
    pub last_seen_at: Option<f64>,
    pub connected: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct ShareLink {
    pub id: String,
    pub pane_session_key: String,
    pub label: Option<String>,
    pub recipient: Option<String>,
    pub created_at: f64,
    pub expires_at: Option<f64>,
}

/// Everything the page shows, read in one go. `error` is set (and the rest
/// left default) when the gateway does not answer.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Snapshot {
    pub error: Option<String>,
    pub status: Status,
    pub config: Config,
    pub code: String,
    pub pair_url: String,
    pub devices: Vec<Device>,
    pub shares: Vec<ShareLink>,
}

impl Snapshot {
    pub fn reachable(&self) -> bool {
        self.error.is_none()
    }
}

fn parse<T: for<'de> Deserialize<'de> + Default>(v: Value) -> T {
    serde_json::from_value(v).unwrap_or_default()
}

pub fn read() -> Snapshot {
    let status = match call("gateway.status", json!({})) {
        Ok(v) => parse::<Status>(v),
        Err(e) => return Snapshot { error: Some(e), ..Snapshot::default() },
    };
    let config = call("gateway.config.get", json!({})).map(parse::<Config>).unwrap_or_default();
    let code = call("pairing.code.get", json!({})).unwrap_or_default();
    let devices = call("devices.list", json!({})).map(|v| parse::<Vec<Device>>(v["devices"].clone())).unwrap_or_default();
    let shares = call("share.list", json!({})).map(|v| parse::<Vec<ShareLink>>(v["links"].clone())).unwrap_or_default();
    Snapshot {
        error: None,
        status,
        config,
        code: code["code"].as_str().unwrap_or_default().to_string(),
        pair_url: code["pair_url"].as_str().unwrap_or_default().to_string(),
        devices,
        shares,
    }
}

/// `gateway.config.set` with a partial `{web?, telegram?}`; applied live.
pub fn set_config(partial: Value) -> Result<(), String> {
    call("gateway.config.set", partial).map(|_| ())
}

pub fn refresh_code() -> Result<(), String> {
    call("pairing.code.refresh", json!({})).map(|_| ())
}

/// A new root secret and code: every device is signed out.
pub fn revoke_all() -> Result<(), String> {
    call("pairing.revoke_all", json!({})).map(|_| ())
}

pub fn revoke_device(id: &str) -> Result<(), String> {
    call("devices.revoke", json!({"id": id})).map(|_| ())
}

pub fn revoke_share(id: &str) -> Result<(), String> {
    call("share.revoke", json!({"id": id})).map(|_| ())
}

/// How long a share link lives: the macOS app's `ShareLinkLifetime`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Lifetime {
    Hour,
    Day,
    Week,
    Never,
}

impl Lifetime {
    pub const ALL: [Lifetime; 4] = [Lifetime::Hour, Lifetime::Day, Lifetime::Week, Lifetime::Never];

    pub fn seconds(self) -> Option<u64> {
        match self {
            Lifetime::Hour => Some(3600),
            Lifetime::Day => Some(86_400),
            Lifetime::Week => Some(7 * 86_400),
            Lifetime::Never => None,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Lifetime::Hour => "1 hour",
            Lifetime::Day => "24 hours",
            Lifetime::Week => "7 days",
            Lifetime::Never => "Never",
        }
    }
}

/// A link minted for one pane, with what only the gateway knows about it.
#[derive(Clone, Debug, PartialEq)]
pub struct Shared {
    pub id: String,
    pub url: String,
    pub expires_at: Option<f64>,
    /// Whether the web listener is up, so the link opens anything yet.
    pub listening: bool,
    /// Other live links to the same pane.
    pub others: usize,
}

fn shared(id: String, url: String, expires_at: Option<f64>, pane: &str) -> Shared {
    let listening = call("gateway.status", json!({})).map(parse::<Status>).map(|s| s.web.listening).unwrap_or(false);
    let others = call("share.list", json!({}))
        .map(|v| parse::<Vec<ShareLink>>(v["links"].clone()))
        .unwrap_or_default()
        .iter()
        .filter(|l| l.pane_session_key == pane && l.id != id)
        .count();
    Shared { id, url, expires_at, listening, others }
}

/// `share.create`: a link another machine opens to see only this pane.
pub fn create_share(pane: &str, label: &str, lifetime: Lifetime) -> Result<Shared, String> {
    let v = call("share.create", json!({"pane_session_key": pane, "label": label, "lifetime_seconds": lifetime.seconds()}))?;
    let id = v["id"].as_str().unwrap_or_default().to_string();
    let url = v["url"].as_str().unwrap_or_default().to_string();
    if id.is_empty() || url.is_empty() {
        return Err("seahelm-gateway sent no link".into());
    }
    Ok(shared(id, url, v["expires_at"].as_f64(), pane))
}

/// A new lifetime for a link, counted from now.
pub fn set_share_lifetime(link: &Shared, pane: &str, lifetime: Lifetime) -> Result<Shared, String> {
    let v = call("share.update", json!({"id": link.id, "lifetime_seconds": lifetime.seconds()}))?;
    Ok(shared(link.id.clone(), link.url.clone(), v["expires_at"].as_f64(), pane))
}

/// Every link to a pane.
pub fn revoke_pane_shares(pane: &str) -> Result<(), String> {
    call("share.revoke", json!({"pane_session_key": pane})).map(|_| ())
}

/// The bot's @username for a token, without saving it.
pub fn validate_token(token: &str) -> Result<String, String> {
    let v = call("telegram.validate_token", json!({"bot_token": token}))?;
    if v["ok"].as_bool() == Some(true) {
        Ok(v["username"].as_str().unwrap_or_default().to_string())
    } else {
        Err(v["error"].as_str().unwrap_or("the token was refused").to_string())
    }
}

/// A one-time code: whoever sends `/start <code>` to the bot is added to
/// `allowed_users`. `(code, deep link)`.
pub fn pair_begin() -> Result<(String, String), String> {
    let v = call("telegram.pair.begin", json!({}))?;
    Ok((v["code"].as_str().unwrap_or_default().to_string(), v["deep_link"].as_str().unwrap_or_default().to_string()))
}

pub fn pair_cancel() {
    let _ = call("telegram.pair.cancel", json!({}));
}

/// `allowed_users` as typed: ids or @usernames, split on commas and spaces.
pub fn parse_users(text: &str) -> Vec<String> {
    text.split(|c: char| c == ',' || c.is_whitespace()).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string).collect()
}

/// The port as typed; None unless a usable port number.
pub fn parse_port(text: &str) -> Option<u16> {
    text.trim().parse::<u16>().ok().filter(|p| *p >= 1)
}

/// "just now", "5 min ago", "3 h ago", "2 d ago".
pub fn ago(then: f64, now: f64) -> String {
    let s = (now - then).max(0.0);
    match s {
        s if s < 60.0 => "just now".into(),
        s if s < 3600.0 => format!("{} min ago", (s / 60.0) as u64),
        s if s < 86400.0 => format!("{} h ago", (s / 3600.0) as u64),
        s => format!("{} d ago", (s / 86400.0) as u64),
    }
}

/// When a share link runs out: "no expiry", "expired", "in 3 h".
pub fn expires(at: Option<f64>, now: f64) -> String {
    match at {
        None => "no expiry".into(),
        Some(t) if t <= now => "expired".into(),
        Some(t) => {
            let s = t - now;
            match s {
                s if s < 3600.0 => format!("in {} min", ((s / 60.0) as u64).max(1)),
                s if s < 86400.0 => format!("in {} h", (s / 3600.0) as u64),
                s => format!("in {} d", (s / 86400.0) as u64),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_gateways_shapes() {
        let s: Status = parse(json!({"web": {"enabled": true, "listening": true, "port": 2783, "public_url": "http://10.0.0.2:2783", "error": null, "clients": 2},
                                    "telegram": {"enabled": true, "configured": true, "connected": false, "bot_username": null, "error": "401"},
                                    "core": {"reachable": true}}));
        assert!(s.web.listening && s.core.reachable);
        assert_eq!(s.web.clients, 2);
        assert_eq!(s.telegram.error.as_deref(), Some("401"));
        let c: Config = parse(json!({"web": {"enabled": false, "port": 2783, "public_url": null, "web_root": null, "telegram_host": null},
                                    "telegram": {"enabled": true, "allowed_users": ["@me", "42"], "default_chat_id": null, "backfill_seconds": 60.0,
                                                 "rules": [], "mini_app_url": null, "bot_token_set": true}}));
        assert!(c.telegram.bot_token_set);
        assert_eq!(c.telegram.allowed_users, vec!["@me", "42"]);
        let d: Vec<Device> = parse(json!([{"id": "a", "label": "Chrome on Mac", "via": "code", "created_at": 1.0, "last_seen_at": null, "connected": true}]));
        assert_eq!(d[0].label, "Chrome on Mac");
        // Missing pieces fall back rather than fail.
        assert_eq!(parse::<Status>(json!(null)), Status::default());
    }

    #[test]
    fn users_and_ports_as_typed() {
        assert_eq!(parse_users(" @alice, 12345  @bob,,"), vec!["@alice", "12345", "@bob"]);
        assert!(parse_users("  ").is_empty());
        assert_eq!(parse_port(" 2783 "), Some(2783));
        assert_eq!(parse_port("0"), None);
        assert_eq!(parse_port("70000"), None);
        assert_eq!(parse_port("web"), None);
    }

    #[test]
    fn times_read_plainly() {
        assert_eq!(ago(100.0, 130.0), "just now");
        assert_eq!(ago(0.0, 600.0), "10 min ago");
        assert_eq!(ago(0.0, 7300.0), "2 h ago");
        assert_eq!(ago(0.0, 3.0 * 86400.0), "3 d ago");
        assert_eq!(expires(None, 0.0), "no expiry");
        assert_eq!(expires(Some(10.0), 20.0), "expired");
        assert_eq!(expires(Some(20.0), 0.0), "in 1 min");
        assert_eq!(expires(Some(7200.0), 0.0), "in 2 h");
    }

    /// Against the running gateway, read-only: `cargo test -- --ignored live_read`.
    #[test]
    #[ignore]
    fn live_read() {
        let s = read();
        assert!(s.reachable(), "{:?}", s.error);
        println!("web: {:?}", s.status.web);
        println!("telegram: {:?} / config users {}", s.status.telegram, s.config.telegram.allowed_users.len());
        println!("code len {} pair_url {} devices {} shares {}", s.code.len(), s.pair_url, s.devices.len(), s.shares.len());
        for d in &s.devices {
            println!("  device {} via {} connected {}", d.label, d.via, d.connected);
        }
        assert_eq!(s.config.web.port, s.status.web.port);
    }
}
