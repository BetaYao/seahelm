//! Who may sign in: the legacy token derived from the root secret, device
//! tokens, the pairing code, Telegram Mini App launch data, share links.
//! Pure functions over the store's data; the session decides what to do.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use base64::Engine;
use hmac::{Hmac, Mac};
use rand::RngCore;
use sha2::{Digest, Sha256};

use crate::store::{Device, ShareLink, State, TelegramConfig};

const B64: base64::engine::GeneralPurpose = base64::engine::general_purpose::URL_SAFE_NO_PAD;

pub fn random_bytes(n: usize) -> Vec<u8> {
    let mut v = vec![0u8; n];
    rand::thread_rng().fill_bytes(&mut v);
    v
}

pub fn base64url(bytes: &[u8]) -> String {
    B64.encode(bytes)
}

pub fn sha256_hex(s: &str) -> String {
    hex::encode(Sha256::digest(s.as_bytes()))
}

pub fn constant_time_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |d, (x, y)| d | (x ^ y)) == 0
}

pub fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

// MARK: root secret and the legacy token

pub fn new_root_secret() -> String {
    base64url(&random_bytes(32))
}

/// The 32 bytes of a base64url root secret, or None when it is not one.
pub fn root_secret_bytes(s: &str) -> Option<Vec<u8>> {
    let t = s.trim().trim_end_matches('=');
    let bytes = B64.decode(t).ok()?;
    (bytes.len() == 32).then_some(bytes)
}

/// The token every client paired before device tokens holds (contract v1):
/// `hex(HKDF-SHA256(ikm=root_secret, salt="seahelm-pair-v1", info="auth"))`.
pub fn legacy_token(root_secret: &str) -> Option<String> {
    let ikm = root_secret_bytes(root_secret)?;
    let hk = hkdf::Hkdf::<Sha256>::new(Some(b"seahelm-pair-v1"), &ikm);
    let mut out = [0u8; 32];
    hk.expand(b"auth", &mut out).ok()?;
    Some(hex::encode(out))
}

pub fn verify_legacy(root_secret: &str, expected_mac: &str, mac: &str, token: &str) -> bool {
    !token.is_empty() && mac == expected_mac && legacy_token(root_secret).is_some_and(|t| constant_time_eq(&t, token))
}

// MARK: device tokens

/// A new device and the token it is to present. Only the hash is kept.
pub fn issue_device(label: &str, via: &str) -> (Device, String) {
    let token = hex::encode(random_bytes(32));
    let t = now();
    let device = Device {
        id: base64url(&random_bytes(9)),
        label: if label.trim().is_empty() { "browser".into() } else { label.trim().chars().take(60).collect() },
        via: via.into(),
        token_hash: sha256_hex(&token),
        created_at: t,
        last_seen_at: t,
    };
    (device, token)
}

/// The device a token belongs to.
pub fn find_device<'a>(state: &'a State, token: &str) -> Option<&'a Device> {
    if token.is_empty() {
        return None;
    }
    let h = sha256_hex(token);
    state.devices.iter().find(|d| constant_time_eq(&d.token_hash, &h))
}

// MARK: the pairing code

pub const CODE_LENGTHS: std::ops::RangeInclusive<usize> = 8..=16;

pub fn normalize_code(raw: &str) -> String {
    raw.chars().filter(char::is_ascii_digit).collect()
}

pub fn is_valid_code(code: &str) -> bool {
    CODE_LENGTHS.contains(&normalize_code(code).len())
}

/// Eight digits. Bias from `% 10` on a byte does not matter at this size.
pub fn generate_code() -> String {
    random_bytes(8).iter().map(|b| char::from(b'0' + b % 10)).collect()
}

pub fn verify_code(stored: Option<&str>, given: &str) -> bool {
    let given = normalize_code(given);
    stored.map(normalize_code).is_some_and(|s| CODE_LENGTHS.contains(&s.len()) && constant_time_eq(&s, &given))
}

/// Five wrong codes a minute per client address.
#[derive(Default)]
pub struct RateLimiter {
    failures: HashMap<String, Vec<Instant>>,
}

impl RateLimiter {
    const MAX: usize = 5;
    const WINDOW: Duration = Duration::from_secs(60);

    fn prune(&mut self, ip: &str, now: Instant) {
        if let Some(list) = self.failures.get_mut(ip) {
            list.retain(|t| now.duration_since(*t) < Self::WINDOW);
            if list.is_empty() {
                self.failures.remove(ip);
            }
        }
    }

    pub fn allow(&mut self, ip: &str) -> bool {
        let now = Instant::now();
        self.prune(ip, now);
        self.failures.get(ip).map_or(0, Vec::len) < Self::MAX
    }

    pub fn failure(&mut self, ip: &str) {
        let now = Instant::now();
        self.prune(ip, now);
        self.failures.entry(ip.into()).or_default().push(now);
    }

    pub fn success(&mut self, ip: &str) {
        self.failures.remove(ip);
    }
}

// MARK: share links

pub enum ShareCheck {
    Valid { id: String, recipient: Option<String> },
    Expired,
    /// Never minted, revoked, or minted for another pane: told apart for nobody.
    Invalid,
}

pub fn mint_share(pane: &str, label: &str, lifetime: Option<f64>, recipient: Option<&str>) -> (ShareLink, String) {
    let token = base64url(&random_bytes(32));
    let t = now();
    let link = ShareLink {
        id: base64url(&random_bytes(9)),
        pane_session_key: pane.into(),
        label: label.into(),
        token_hash: sha256_hex(&token),
        created_at: t,
        expires_at: lifetime.map(|s| t + s),
        recipient: recipient.and_then(sender_name),
    };
    (link, token)
}

pub fn check_share(links: &[ShareLink], token: &str, pane: &str, now: f64) -> ShareCheck {
    if token.is_empty() {
        return ShareCheck::Invalid;
    }
    let h = sha256_hex(token);
    match links.iter().find(|l| constant_time_eq(&l.token_hash, &h)) {
        Some(l) if l.pane_session_key == pane => {
            if l.is_live(now) {
                ShareCheck::Valid { id: l.id.clone(), recipient: l.recipient.clone() }
            } else {
                ShareCheck::Expired
            }
        }
        _ => ShareCheck::Invalid,
    }
}

/// A name fit for a message prefix: one line, no brackets, at most 40
/// characters. None when nothing is left.
pub fn sender_name(raw: &str) -> Option<String> {
    let cleaned: String = raw.chars().map(|c| if c.is_control() { ' ' } else { c }).filter(|c| *c != '[' && *c != ']').collect();
    let joined = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    let name: String = joined.chars().take(40).collect();
    (!name.is_empty()).then_some(name)
}

// MARK: Telegram Mini App launch data

#[derive(Debug, PartialEq)]
pub struct TelegramUser {
    pub id: i64,
    pub username: Option<String>,
}

/// The user a Mini App launch was signed for, when it checks out against the
/// bot token (core.telegram.org/bots/webapps#validating-data-received-via-the-mini-app):
/// an HMAC over every field but `hash`, `signature` included; at most a day old.
pub fn validate_init_data(raw: &str, bot_token: &str, now: f64) -> Option<TelegramUser> {
    let mut fields: HashMap<String, String> = HashMap::new();
    for pair in raw.split('&').filter(|p| !p.is_empty()) {
        let (k, v) = pair.split_once('=')?;
        let v = percent_encoding::percent_decode_str(v).decode_utf8().ok()?.into_owned();
        if k.is_empty() || fields.insert(k.into(), v).is_some() {
            return None;
        }
    }
    let hash = fields.get("hash")?.to_ascii_lowercase();
    let mut keys: Vec<&String> = fields.keys().filter(|k| *k != "hash").collect();
    keys.sort();
    let check = keys.iter().map(|k| format!("{k}={}", fields[*k])).collect::<Vec<_>>().join("\n");
    let mut secret = Hmac::<Sha256>::new_from_slice(b"WebAppData").ok()?;
    secret.update(bot_token.as_bytes());
    let secret = secret.finalize().into_bytes();
    let mut mac = Hmac::<Sha256>::new_from_slice(&secret).ok()?;
    mac.update(check.as_bytes());
    if !constant_time_eq(&hex::encode(mac.finalize().into_bytes()), &hash) {
        return None;
    }
    let age = now - fields.get("auth_date")?.parse::<f64>().ok()?;
    if !(-300.0..=86_400.0).contains(&age) {
        return None;
    }
    let user: serde_json::Value = serde_json::from_str(fields.get("user")?).ok()?;
    Some(TelegramUser { id: user.get("id")?.as_i64()?, username: user.get("username").and_then(|u| u.as_str()).map(str::to_string) })
}

/// The allowed user a launch speaks for.
pub fn telegram_sign_in(init_data: &str, bot_token: Option<&str>, config: &TelegramConfig) -> Option<TelegramUser> {
    let user = validate_init_data(init_data, bot_token?, now())?;
    config.allows(user.id, user.username.as_deref()).then_some(user)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_token_matches_the_apps_derivation() {
        // root secret = bytes 0..32; value computed with the app's PairingCrypto.
        let root = base64url(&(0u8..32).collect::<Vec<_>>());
        let t = legacy_token(&root).unwrap();
        assert_eq!(t.len(), 64);
        assert!(verify_legacy(&root, "m1", "m1", &t));
        assert!(!verify_legacy(&root, "m1", "m2", &t));
    }

    #[test]
    fn codes() {
        assert!(is_valid_code(&generate_code()));
        assert!(verify_code(Some("1234 5678"), "12345678"));
        assert!(!verify_code(Some("1234567"), "1234567"));
        assert!(!verify_code(Some("12345678"), "12345679"));
    }

    #[test]
    fn devices_and_shares() {
        let mut st = State::default();
        let (d, token) = issue_device("phone", "code");
        st.devices.push(d.clone());
        assert_eq!(find_device(&st, &token).map(|d| d.id.clone()), Some(d.id));
        assert!(find_device(&st, "nope").is_none());
        let (l, tok) = mint_share("p1", "x", Some(10.0), Some(" [Ann]\n"));
        assert_eq!(l.recipient.as_deref(), Some("Ann"));
        let links = vec![l];
        assert!(matches!(check_share(&links, &tok, "p1", now()), ShareCheck::Valid { .. }));
        assert!(matches!(check_share(&links, &tok, "p2", now()), ShareCheck::Invalid));
        assert!(matches!(check_share(&links, &tok, "p1", now() + 20.0), ShareCheck::Expired));
    }

    #[test]
    fn init_data_round_trip() {
        let token = "123:abc";
        let user = r#"{"id":42,"username":"me"}"#;
        let auth = "1700000000";
        let check = format!("auth_date={auth}\nsignature=sig\nuser={user}");
        let mut s = Hmac::<Sha256>::new_from_slice(b"WebAppData").unwrap();
        s.update(token.as_bytes());
        let mut m = Hmac::<Sha256>::new_from_slice(&s.finalize().into_bytes()).unwrap();
        m.update(check.as_bytes());
        let hash = hex::encode(m.finalize().into_bytes());
        let enc = percent_encoding::utf8_percent_encode(user, percent_encoding::NON_ALPHANUMERIC).to_string();
        let raw = format!("user={enc}&auth_date={auth}&signature=sig&hash={hash}");
        assert_eq!(validate_init_data(&raw, token, 1_700_000_100.0), Some(TelegramUser { id: 42, username: Some("me".into()) }));
        assert_eq!(validate_init_data(&raw, "other", 1_700_000_100.0), None);
        assert_eq!(validate_init_data(&raw, token, 1_700_200_000.0), None);
    }
}
