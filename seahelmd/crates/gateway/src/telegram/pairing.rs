//! A one-time code that turns "whoever taps Start" into an allowed user.
//!
//! The code rides in a `t.me/<bot>?start=<code>` deep link, so its alphabet
//! is what Telegram accepts in a start payload; ambiguous glyphs are left
//! out so it can also be read off a screen and typed. It dies on use and on
//! a timer: a code that lived for ever would be a second, quieter allowlist.

use rand::Rng;

/// No `0`/`O`, no `1`/`I`/`L`.
pub const ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789";
pub const LENGTH: usize = 8;
/// Long enough to walk to a phone, short enough that Settings left open over
/// lunch does not leave the door open with it.
pub const TTL_SECS: f64 = 600.0;

pub fn generate() -> String {
    let mut rng = rand::thread_rng();
    (0..LENGTH).map(|_| ALPHABET[rng.gen_range(0..ALPHABET.len())] as char).collect()
}

/// Uppercased, everything outside the alphabet (spaces, dashes) dropped.
pub fn normalize(raw: &str) -> String {
    raw.to_uppercase().chars().filter(|c| c.is_ascii() && ALPHABET.contains(&(*c as u8))).collect()
}

/// Constant-time compare of two codes.
pub fn matches(expected: &str, candidate: &str) -> bool {
    let (a, b) = (normalize(expected), normalize(candidate));
    a.len() == LENGTH && b.len() == LENGTH && crate::auth::constant_time_eq(&a, &b)
}

pub fn deep_link(bot_username: &str, code: &str) -> String {
    format!("https://t.me/{}?start={}", bot_username.trim_start_matches('@'), normalize(code))
}

/// The armed code: good for one pairing, until it expires.
#[derive(Debug, Clone)]
pub struct Session {
    pub code: String,
    pub expires_at: f64,
    consumed: bool,
}

impl Session {
    pub fn new(now: f64) -> Session {
        Session::with_code(generate(), now)
    }

    pub fn with_code(code: String, now: f64) -> Session {
        Session { code, expires_at: now + TTL_SECS, consumed: false }
    }

    pub fn is_live(&self, now: f64) -> bool {
        !self.consumed && now < self.expires_at
    }

    /// Verify and spend in one step: a forwarded link or a retry gets false,
    /// so a pairing cannot be replayed into a second allowlist entry.
    pub fn claim(&mut self, candidate: &str, now: f64) -> bool {
        if !self.is_live(now) || !matches(&self.code, candidate) {
            return false;
        }
        self.consumed = true;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_use_the_alphabet() {
        for _ in 0..50 {
            let c = generate();
            assert_eq!(c.len(), LENGTH);
            assert_eq!(normalize(&c), c);
        }
        assert_eq!(normalize("ab-cd ef12"), "ABCDEF2");
        assert!(matches("ABCD2345", "abcd-2345"));
        assert!(!matches("ABCD2345", "ABCD2346"));
        assert_eq!(deep_link("@helm_bot", "abcd2345"), "https://t.me/helm_bot?start=ABCD2345");
    }

    #[test]
    fn a_code_pairs_once_and_expires() {
        let mut s = Session::with_code("ABCD2345".into(), 1000.0);
        assert!(!s.claim("WRONG234", 1001.0));
        assert!(s.claim("abcd2345", 1001.0));
        assert!(!s.claim("ABCD2345", 1002.0));
        let mut late = Session::with_code("ABCD2345".into(), 1000.0);
        assert!(!late.claim("ABCD2345", 1000.0 + TTL_SECS));
    }
}
