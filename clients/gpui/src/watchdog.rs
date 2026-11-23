//! Keeping seahelm-core and seahelm-gateway running, as the macOS app's
//! `CoreLink` and `GatewayLink` do: a ping every `PING_EVERY`, and
//! `<service> ensure` again — at most every `ENSURE_EVERY` — once one has
//! stopped answering for a few seconds. `ensure` starts a service only when
//! nothing answers, so it never replaces a live one. The workspace runs the
//! loop off the UI thread and shows a service that stays silent past
//! `WARN_AFTER` (the island's `GW` badge).

use std::time::{Duration, Instant};

pub const PING_EVERY: Duration = Duration::from_secs(5);
pub const ENSURE_EVERY: Duration = Duration::from_secs(15);
/// Silent this long before an `ensure` (`CoreLink.shouldEnsure`'s 4 s):
/// one missed ping on a busy service is not worth starting another.
pub const ENSURE_AFTER: Duration = Duration::from_secs(4);
/// Silent this long before the window says so (`IslandWarning.gatewayGrace`).
pub const WARN_AFTER: Duration = Duration::from_secs(12);

/// One service, as the pings saw it.
#[derive(Clone, Copy, Debug, Default)]
pub struct Watch {
    /// When it stopped answering; None while it answers.
    pub silent_since: Option<Instant>,
    last_ensure: Option<Instant>,
}

impl Watch {
    /// `ensure` ran at `now` (the client's start runs one).
    pub fn ensured(&mut self, now: Instant) {
        self.last_ensure = Some(now);
    }

    /// A ping's outcome. True when it is time for an `ensure`, which the
    /// caller then runs (and this records).
    pub fn ping(&mut self, answered: bool, now: Instant) -> bool {
        if answered {
            self.silent_since = None;
            return false;
        }
        let since = *self.silent_since.get_or_insert(now);
        if now.duration_since(since) < ENSURE_AFTER {
            return false;
        }
        if self.last_ensure.is_some_and(|t| now.duration_since(t) < ENSURE_EVERY) {
            return false;
        }
        self.last_ensure = Some(now);
        true
    }

    /// Silent long enough to say so.
    pub fn warn(&self, now: Instant) -> bool {
        self.silent_since.is_some_and(|s| now.duration_since(s) >= WARN_AFTER)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_answering_service_is_left_alone() {
        let t = Instant::now();
        let mut w = Watch::default();
        w.ensured(t);
        for i in 0..10 {
            assert!(!w.ping(true, t + PING_EVERY * i));
        }
        assert!(!w.warn(t + Duration::from_secs(60)));
    }

    #[test]
    fn a_silent_service_is_ensured_at_most_every_fifteen_seconds() {
        let t = Instant::now();
        let mut w = Watch::default();
        w.ensured(t);
        let s = |n: u64| t + Duration::from_secs(n);
        assert!(!w.ping(false, s(5)), "silent for no time yet");
        assert!(!w.ping(false, s(10)), "silent 5 s, but the start's ensure was 10 s ago");
        assert!(w.ping(false, s(15)), "silent 10 s, last ensure 15 s ago");
        assert!(!w.ping(false, s(20)));
        assert!(!w.ping(false, s(25)));
        assert!(w.ping(false, s(30)));
        assert!(w.warn(s(30)));
    }

    #[test]
    fn the_warning_waits_twelve_seconds_and_clears_on_an_answer() {
        let t = Instant::now();
        let mut w = Watch::default();
        w.ping(false, t);
        assert!(!w.warn(t + Duration::from_secs(11)));
        assert!(w.warn(t + WARN_AFTER));
        w.ping(true, t + Duration::from_secs(13));
        assert!(!w.warn(t + Duration::from_secs(13)));
    }

    #[test]
    fn with_no_ensure_yet_the_first_comes_after_the_grace() {
        let t = Instant::now();
        let mut w = Watch::default();
        assert!(!w.ping(false, t));
        assert!(w.ping(false, t + ENSURE_AFTER));
    }
}
