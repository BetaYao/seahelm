//! When the user is there (docs/first-mate-autonomy.md, "When the brief goes
//! out (D8)"): what the core already sees, kept as a small activity profile
//! so the brief can go out when the user picks things up instead of at a
//! fixed hour.
//!
//! Signals, each one moment the user did something (never a state that can
//! sit unchanged overnight):
//!
//! - a desktop client coming to the front, or changing what it shows while
//!   in front (`client.visible`, per client; a client the core has not heard
//!   from since it started is not a transition, so a core restart is not an
//!   arrival);
//! - the user's prompt in a pane's timeline, unless something typed into that
//!   pane a moment before (First Mate, an agent's `seahelm pane run`, a chat);
//! - a card answered or dismissed, words to First Mate, a command line — the
//!   calls the peer check lets through only from the user's clients — with
//!   their channel from `_meta.via`.
//!
//! The profile: per weekday, 96 quarter-hour buckets, each a decayed count
//! of the days the user was active then (`budget::tuning::PROFILE_DECAY` per
//! week). Plus the last moment seen, per channel and overall, and the last
//! arrival (the first signal after `ARRIVAL_GAP` without one). It lives in
//! `first-mate/activity.json` and is kept whether First Mate is on or not,
//! like the observation log: by the time it is turned on, it knows when the
//! user starts the day.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use super::budget::tuning;

pub const FILE_NAME: &str = "activity.json";
pub const BUCKETS: usize = 96;
const BUCKET_SECS: f64 = 900.0;
/// How often the profile is written while signals come in (an arrival is
/// written at once).
const SAVE_EVERY: f64 = 300.0;

/// Where the user did it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Channel {
    /// The macOS app, the GPUI client, or the user's own terminal.
    Desktop,
    Telegram,
    /// seahelm-web, a share link.
    Web,
}

impl Channel {
    /// From a call's `_meta.via` (`telegram:@me`, `web:Safari`, `share:…`);
    /// a call that says nothing came from a desktop client or a terminal.
    pub fn from_via(via: Option<&str>) -> Channel {
        match via {
            Some(v) if v.starts_with("telegram") => Channel::Telegram,
            Some(v) if v.starts_with("web") || v.starts_with("share") => Channel::Web,
            _ => Channel::Desktop,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Channel::Desktop => "desktop",
            Channel::Telegram => "telegram",
            Channel::Web => "web",
        }
    }
}

/// The first signal after a long gap.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Arrival {
    pub at: f64,
    /// How long the user was away; None for the first signal ever.
    pub away: Option<f64>,
    pub channel: Option<Channel>,
}

/// Days since 1970-01-01 in local time, and a day's weekday (0 = Sunday,
/// as `clock::Local`).
pub fn day_number(now: f64, offset: i64) -> i64 {
    ((now + offset as f64) / 86_400.0).floor() as i64
}

pub fn weekday(day: i64) -> u32 {
    (day + 4).rem_euclid(7) as u32
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Profile {
    /// `[weekday][bucket]`, decayed day counts.
    #[serde(default)]
    pub weights: Vec<Vec<f32>>,
    /// The local day `today` belongs to (`day_number`).
    #[serde(default)]
    pub day: Option<i64>,
    /// Buckets with a signal on that day, folded into `weights` when the day
    /// is over.
    #[serde(default)]
    pub today: BTreeSet<u16>,
    #[serde(default)]
    pub last_seen: f64,
    #[serde(default)]
    pub prompts: Vec<(f64, String, String)>,
    #[serde(default)]
    pub last_seen_by: BTreeMap<Channel, f64>,
    #[serde(default)]
    pub last_arrival: Option<Arrival>,
}

impl Profile {
    fn ensure_shape(&mut self) {
        if self.weights.len() != 7 || self.weights.iter().any(|r| r.len() != BUCKETS) {
            self.weights = vec![vec![0.0; BUCKETS]; 7];
        }
    }

    /// One signal. Returns the arrival when it is one.
    pub fn record(&mut self, now: f64, offset: i64, channel: Option<Channel>) -> Option<Arrival> {
        self.ensure_shape();
        self.roll(day_number(now, offset));
        let bucket = (((now + offset as f64).rem_euclid(86_400.0)) / BUCKET_SECS) as u16;
        self.today.insert(bucket.min(BUCKETS as u16 - 1));
        let arrival = if self.last_seen <= 0.0 {
            Some(Arrival { at: now, away: None, channel })
        } else if now - self.last_seen >= tuning::ARRIVAL_GAP {
            Some(Arrival { at: now, away: Some(now - self.last_seen), channel })
        } else {
            None
        };
        if now > self.last_seen {
            self.last_seen = now;
        }
        if let Some(c) = channel {
            let e = self.last_seen_by.entry(c).or_default();
            if now > *e {
                *e = now;
            }
        }
        if let Some(a) = &arrival {
            self.last_arrival = Some(a.clone());
        }
        arrival
    }

    /// Move to `day`, folding the days that ended (a day with no signal at
    /// all decays its weekday too, so a habit that stopped fades).
    pub fn roll(&mut self, day: i64) {
        self.ensure_shape();
        match self.day {
            None => self.day = Some(day),
            Some(d) if day > d => {
                let set = std::mem::take(&mut self.today);
                self.fold(d, &set);
                for missed in (d + 1..day).take(tuning::MAX_FOLDED_DAYS) {
                    self.fold(missed, &BTreeSet::new());
                }
                self.day = Some(day);
            }
            // The same day, or the clock went back: keep counting it.
            _ => {}
        }
    }

    fn fold(&mut self, day: i64, set: &BTreeSet<u16>) {
        let row = &mut self.weights[weekday(day) as usize];
        for (b, w) in row.iter_mut().enumerate() {
            *w = *w * tuning::PROFILE_DECAY + if set.contains(&(b as u16)) { 1.0 } else { 0.0 };
        }
    }

    /// The usual start of the user's day on `weekday`, as a minute of the
    /// day: the first quarter-hour from `DAY_STARTS_AT` on (so a late night
    /// is not taken for an early start) whose weight is at least
    /// `START_SHARE` of the busiest one. A weekday never seen falls back to
    /// the average of the others; None while the profile knows nothing.
    pub fn usual_start(&self, weekday: u32) -> Option<u32> {
        if self.weights.len() != 7 {
            return None;
        }
        let row_max = |r: &Vec<f32>| r.iter().copied().fold(0.0f32, f32::max);
        let own = &self.weights[weekday as usize % 7];
        let row: Vec<f32> = if row_max(own) >= tuning::PROFILE_MIN_WEIGHT {
            own.clone()
        } else {
            let known: Vec<&Vec<f32>> = self.weights.iter().filter(|r| row_max(r) >= tuning::PROFILE_MIN_WEIGHT).collect();
            if known.is_empty() {
                return None;
            }
            (0..BUCKETS).map(|b| known.iter().map(|r| r[b]).sum::<f32>() / known.len() as f32).collect()
        };
        let max = row_max(&row);
        if max <= 0.0 {
            return None;
        }
        let first = (tuning::DAY_STARTS_AT / 15) as usize;
        (first..BUCKETS).chain(0..first).find(|b| row[*b] >= tuning::START_SHARE * max).map(|b| b as u32 * 15)
    }

    /// When the user was last seen on `channel`.
    pub fn seen_on(&self, channel: Channel) -> f64 {
        self.last_seen_by.get(&channel).copied().unwrap_or(0.0)
    }
}

/// What First Mate reads to decide when and where the brief goes.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Snapshot {
    pub profile: Profile,
    /// A desktop client says it is in front now.
    pub desktop_in_front: bool,
}

impl Snapshot {
    /// `presence.state`, read-only: what the brief's timing goes by.
    pub fn to_json(&self, now: f64, offset: i64) -> serde_json::Value {
        let p = &self.profile;
        let by: serde_json::Map<String, serde_json::Value> = p.last_seen_by.iter().map(|(c, at)| (c.as_str().to_string(), serde_json::json!(at))).collect();
        let today = weekday(day_number(now - tuning::DAY_STARTS_AT as f64 * 60.0, offset));
        let start = p.usual_start(today).map(|m| format!("{:02}:{:02}", m / 60, m % 60));
        serde_json::json!({
            "active": self.active(now),
            "desktop_in_front": self.desktop_in_front,
            "last_seen": p.last_seen,
            "last_seen_by": by,
            "last_arrival": p.last_arrival.as_ref().map(|a| serde_json::json!({"at": a.at, "away": a.away, "channel": a.channel.map(Channel::as_str)})),
            "usual_start_today": start,
        })
    }

    /// A signal within `ACTIVE_WINDOW`.
    pub fn active(&self, now: f64) -> bool {
        self.profile.last_seen > 0.0 && now - self.profile.last_seen <= tuning::ACTIVE_WINDOW
    }
}

/// The core's copy: the profile, where it is written, and the panes
/// something typed into a moment ago (their next prompt is not the user's).
#[derive(Debug, Default)]
pub struct Tracker {
    pub profile: Profile,
    path: Option<PathBuf>,
    saved_at: f64,
    /// Per pane: what was typed into it and when.
    typed_into: HashMap<String, Vec<(String, f64)>>,
}

/// A prompt's text as compared with what was typed: whitespace collapsed,
/// the first 200 characters.
fn echo_key(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(200).collect()
}

impl Tracker {
    pub fn open(path: Option<PathBuf>) -> Self {
        let profile = path.as_ref().and_then(|p| std::fs::read_to_string(p).ok()).and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
        Tracker { profile, path, saved_at: 0.0, typed_into: HashMap::new() }
    }

    pub fn record(&mut self, now: f64, offset: i64, channel: Option<Channel>) -> Option<Arrival> {
        let a = self.profile.record(now, offset, channel);
        if a.is_some() || now - self.saved_at >= SAVE_EVERY {
            self.save(now);
        }
        a
    }

    fn save(&mut self, now: f64) {
        self.saved_at = now;
        let Some(path) = &self.path else { return };
        if let Some(d) = path.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        let tmp = path.with_extension("tmp");
        if std::fs::write(&tmp, serde_json::to_string(&self.profile).unwrap_or_default()).is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }

    /// Something other than the user's keyboard typed `text` into this pane.
    pub fn typed_into(&mut self, pane: &str, text: &str, now: f64) {
        for v in self.typed_into.values_mut() {
            v.retain(|(_, at)| now - *at <= tuning::PROGRAMMATIC_ECHO_TEXT);
        }
        self.typed_into.retain(|_, v| !v.is_empty());
        self.typed_into.entry(pane.to_string()).or_default().push((echo_key(text), now));
    }

    /// Whether anything other than the user's keyboard typed into this pane
    /// within `secs`: a user-only call from that pane's shell may be an
    /// agent driving it (`pane.run` into the user's shell).
    pub fn typed_within(&self, pane: &str, secs: f64, now: f64) -> bool {
        self.typed_into.get(pane).is_some_and(|v| v.iter().any(|(_, at)| now - *at <= secs))
    }

    /// Whether a prompt that showed up in this pane now is the echo of
    /// something typed into it: anything typed a moment ago, or the same
    /// text within `PROGRAMMATIC_ECHO_TEXT`.
    pub fn is_echo(&self, pane: &str, text: &str, now: f64) -> bool {
        let key = echo_key(text);
        self.typed_into.get(pane).is_some_and(|v| {
            v.iter().any(|(t, at)| {
                let age = now - *at;
                age <= tuning::PROGRAMMATIC_ECHO || (age <= tuning::PROGRAMMATIC_ECHO_TEXT && !key.is_empty() && (key.starts_with(t.as_str()) || t.starts_with(key.as_str())))
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 2026-11-02 00:00 UTC, a Monday.
    const MONDAY: f64 = 1_793_577_600.0;
    const H: f64 = 3600.0;
    const DAY: f64 = 86_400.0;

    #[test]
    fn days_and_weekdays_agree_with_the_clock() {
        let d = day_number(MONDAY + 9.0 * H, 0);
        assert_eq!(weekday(d), 1);
        assert_eq!(weekday(d), super::super::clock::Local::with_offset(MONDAY + 9.0 * H, 0).weekday);
        // East of UTC the local day starts earlier.
        assert_eq!(day_number(MONDAY - 1.0 * H, 8 * 3600), d);
    }

    #[test]
    fn buckets_fold_into_their_weekday_and_decay() {
        let mut p = Profile::default();
        p.record(MONDAY + 9.0 * H + 5.0 * 60.0, 0, Some(Channel::Desktop));
        p.record(MONDAY + 9.0 * H + 10.0 * 60.0, 0, None);
        p.record(MONDAY + 14.0 * H, 0, None);
        assert_eq!(p.today, [36u16, 56].into_iter().collect());
        assert!(p.weights[1].iter().all(|w| *w == 0.0), "not folded until the day is over");
        // Tuesday: Monday folds.
        p.record(MONDAY + DAY + 10.0 * H, 0, None);
        assert_eq!(p.weights[1][36], 1.0);
        assert_eq!(p.weights[1][56], 1.0);
        assert_eq!(p.weights[1][40], 0.0);
        assert_eq!(p.today, [40u16].into_iter().collect());
        // A week later, Monday again with only 09:00: 14:00 decays.
        p.record(MONDAY + 7.0 * DAY + 9.0 * H, 0, None);
        p.record(MONDAY + 8.0 * DAY + 9.0 * H, 0, None);
        assert!((p.weights[1][36] - (tuning::PROFILE_DECAY + 1.0)).abs() < 1e-6);
        assert!((p.weights[1][56] - tuning::PROFILE_DECAY).abs() < 1e-6);
        // Tuesday folded once, on its own day; the empty days after it were other weekdays.
        assert_eq!(p.weights[2][40], 1.0);
    }

    #[test]
    fn a_long_absence_fades_every_weekday_but_only_so_far() {
        let mut p = Profile::default();
        p.record(MONDAY + 9.0 * H, 0, None);
        p.record(MONDAY + 400.0 * DAY, 0, None);
        // Monday folded with its signal, then at most MAX_FOLDED_DAYS empty days.
        let w = p.weights[1][36];
        assert!(w > 0.0 && w < 1.0, "{w}");
    }

    #[test]
    fn arrival_is_the_first_signal_after_a_gap() {
        let mut p = Profile::default();
        let first = p.record(MONDAY + 9.0 * H, 0, Some(Channel::Desktop)).unwrap();
        assert_eq!(first.away, None);
        assert!(p.record(MONDAY + 12.0 * H, 0, None).is_none(), "three hours is not a gap");
        let a = p.record(MONDAY + 16.0 * H + 1.0, 0, Some(Channel::Telegram)).unwrap();
        assert_eq!(a.channel, Some(Channel::Telegram));
        assert!((a.away.unwrap() - (4.0 * H + 1.0)).abs() < 1e-6);
        assert_eq!(p.last_arrival, Some(a));
        assert_eq!(p.seen_on(Channel::Telegram), MONDAY + 16.0 * H + 1.0);
        assert_eq!(p.seen_on(Channel::Web), 0.0);
        // A signal from the past (a late row) moves nothing back.
        p.record(MONDAY + 10.0 * H, 0, None);
        assert_eq!(p.last_seen, MONDAY + 16.0 * H + 1.0);
    }

    #[test]
    fn usual_start_skips_late_nights_and_falls_back_to_other_days() {
        let mut p = Profile::default();
        assert_eq!(p.usual_start(1), None, "knows nothing yet");
        // Three Mondays: up past midnight (00:30), at work from 09:15.
        for week in 0..3 {
            let m = MONDAY + week as f64 * 7.0 * DAY;
            p.record(m + 0.5 * H, 0, None);
            p.record(m + 9.25 * H, 0, None);
            p.record(m + 11.0 * H, 0, None);
        }
        p.record(MONDAY + 30.0 * DAY, 0, None);
        assert_eq!(p.usual_start(1), Some(9 * 60 + 15), "the 00:30 bucket is last night's, not the start");
        // Wednesday never seen: the average of the known weekdays.
        assert_eq!(p.usual_start(3), Some(9 * 60 + 15));
    }

    #[test]
    fn channels_from_via() {
        assert_eq!(Channel::from_via(Some("telegram:@me")), Channel::Telegram);
        assert_eq!(Channel::from_via(Some("web:Safari")), Channel::Web);
        assert_eq!(Channel::from_via(Some("share:bob")), Channel::Web);
        assert_eq!(Channel::from_via(None), Channel::Desktop);
    }

    #[test]
    fn typed_prompts_are_echoes_for_a_while() {
        let mut t = Tracker::open(None);
        t.typed_into("s-1", "Fix  the CI\nfailure on #12", 100.0);
        assert!(t.is_echo("s-1", "anything", 100.0 + tuning::PROGRAMMATIC_ECHO), "anything right after");
        assert!(!t.is_echo("s-1", "something else", 101.0 + tuning::PROGRAMMATIC_ECHO));
        // The agent was busy and submitted it at the end of its turn.
        assert!(t.is_echo("s-1", "Fix the CI failure on #12", 100.0 + 20.0 * 60.0));
        assert!(!t.is_echo("s-1", "Fix the CI failure on #12", 101.0 + tuning::PROGRAMMATIC_ECHO_TEXT));
        assert!(!t.is_echo("s-2", "Fix the CI failure on #12", 100.0));
    }

    #[test]
    fn the_profile_survives_a_restart() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join(FILE_NAME);
        let mut t = Tracker::open(Some(path.clone()));
        t.record(MONDAY + 9.0 * H, 0, Some(Channel::Telegram));
        let again = Tracker::open(Some(path));
        assert_eq!(again.profile, t.profile);
        assert_eq!(again.profile.seen_on(Channel::Telegram), MONDAY + 9.0 * H);
    }
}
