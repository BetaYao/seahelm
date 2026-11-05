//! The interruption budget (docs/first-mate-autonomy.md, "Interruption
//! budget", phase 5): when the daily brief goes out and where (D8), which
//! of First Mate's cards go up now and which wait for the brief, the daily
//! cap on proactive cards, and when a card has waited long enough.
//!
//! Pure: the presence (`presence::Snapshot`), the clock and quiet hours are
//! the caller's. First Mate's side is in `brief.rs`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::clock::Local;
use super::lang::Text;
use super::presence::{self, Channel, Snapshot};

/// Every threshold of the budget, in one place: phase 6 tunes them within
/// bounds (D9). The learning loop's own (N, M, expiries to demote) are in
/// `habits::tuning`.
pub mod tuning {
    /// A first signal after this long without one is an arrival.
    pub const ARRIVAL_GAP: f64 = 4.0 * 3600.0;
    /// The user counts as active for this long after a signal.
    pub const ACTIVE_WINDOW: f64 = 20.0 * 60.0;
    /// Not arrived by the usual start plus this: the brief goes to Telegram.
    pub const FALLBACK_AFTER: f64 = 60.0 * 60.0;
    /// The brief's day starts at this minute (04:00 local), not at midnight:
    /// a late night belongs to the day before, and "once a day" means once
    /// between two nights.
    pub const DAY_STARTS_AT: u32 = 4 * 60;
    /// A First Mate card unanswered this long is withdrawn.
    pub const CARD_EXPIRY: f64 = 3.0 * 86_400.0;
    /// Proactive cards a day; beyond it they wait for the next brief.
    pub const DAILY_CARD_CAP: u32 = 3;
    /// Held cards the brief puts up with it at most; the rest are only
    /// listed in it and go up later by the usual rule.
    pub const BRIEF_CARDS: usize = 3;
    /// Telegram is where the user answers if they did within this long.
    pub const TELEGRAM_RECENT: f64 = 14.0 * 86_400.0;
    /// The activity profile: each weekday's buckets decay by this a week…
    pub const PROFILE_DECAY: f32 = 0.8;
    /// …a weekday is known once a bucket reaches this (one day seen)…
    pub const PROFILE_MIN_WEIGHT: f32 = 1.0;
    /// …and the day starts at the first bucket this share of the busiest.
    pub const START_SHARE: f32 = 0.5;
    /// Empty days folded at most after an absence.
    pub const MAX_FOLDED_DAYS: usize = 14;
    /// A prompt in a pane this soon after something typed into it is that
    /// something, not the user…
    pub const PROGRAMMATIC_ECHO: f64 = 90.0;
    /// …and so is one with the same text this soon after (an agent busy
    /// when it was typed submits it at the end of its turn).
    pub const PROGRAMMATIC_ECHO_TEXT: f64 = 30.0 * 60.0;
    /// Items listed per line of the brief.
    pub const BRIEF_LISTED: usize = 5;
}

pub const FILE_NAME: &str = "budget.json";

/// Where a brief goes. It is always written into First Mate's timeline
/// (the island's conversation, the web's); Telegram also gets it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BriefChannel {
    Island,
    Telegram,
}

impl BriefChannel {
    pub fn as_str(self) -> &'static str {
        match self {
            BriefChannel::Island => "island",
            BriefChannel::Telegram => "telegram",
        }
    }
}

/// Why a brief is due now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Due {
    /// The user arrived after a gap.
    Arrival(BriefChannel),
    /// Not arrived by the usual start + `FALLBACK_AFTER`: Telegram, once.
    Fallback,
}

impl Due {
    pub fn channel(self) -> BriefChannel {
        match self {
            Due::Arrival(c) => c,
            Due::Fallback => BriefChannel::Telegram,
        }
    }

    /// Where it goes once we know whether Telegram can be reached: an
    /// arrival meant for Telegram falls back to the timeline; a fallback
    /// brief is not sent at all (and does not count), so it waits for the
    /// user to come back.
    pub fn settle(self, telegram_ready: bool) -> Option<BriefChannel> {
        match (self.channel(), telegram_ready) {
            (BriefChannel::Telegram, true) | (BriefChannel::Island, _) => Some(self.channel()),
            (BriefChannel::Telegram, false) => match self {
                Due::Arrival(_) => Some(BriefChannel::Island),
                Due::Fallback => None,
            },
        }
    }
}

/// `first-mate/budget.json`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct State {
    #[serde(default)]
    pub tuned: super::tuning::State,
    #[serde(default)]
    pub review_enabled_at: f64,
    #[serde(default)]
    pub last_review: f64,
    /// When the last brief went out (unix seconds; 0: never).
    #[serde(default)]
    pub last_brief_at: f64,
    /// The brief day (`brief_day`) the brief was dealt with for: sent, or
    /// found to have nothing to say.
    #[serde(default)]
    pub brief_day: String,
    /// Proactive cards raised on `cards_day`.
    #[serde(default)]
    pub cards_day: String,
    #[serde(default)]
    pub cards_today: u32,
    /// Worktrees the sweep found at `suggest` since the last brief.
    #[serde(default)]
    pub suggest: Vec<String>,
    /// Habit level changes since the last brief, in both languages.
    #[serde(default)]
    pub notes: Vec<Text>,
}

impl State {
    pub fn path(dir: &Path) -> PathBuf {
        dir.join(FILE_NAME)
    }

    pub fn load(path: &Path) -> State {
        let mut state: State = std::fs::read_to_string(path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
        state.tuned.clamp();
        state
    }

    pub fn save(&self, path: &Path) {
        if let Some(d) = path.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        let tmp = path.with_extension("tmp");
        if std::fs::write(&tmp, serde_json::to_string_pretty(self).unwrap_or_default()).is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }

    /// The day's brief went out (or had nothing to say).
    pub fn dealt_with(&mut self, day: &str, sent_at: Option<f64>) {
        self.brief_day = day.to_string();
        if let Some(at) = sent_at {
            self.last_brief_at = at;
            self.suggest.clear();
            self.notes.clear();
        }
    }

    fn cards_on(&mut self, day: &str) -> u32 {
        if self.cards_day != day {
            self.cards_day = day.to_string();
            self.cards_today = 0;
        }
        self.cards_today
    }

    /// Where a card goes: up now (counted against the cap when proactive),
    /// or held for the brief.
    pub fn route(&mut self, class: Class, day: &str, user_active: bool) -> Route {
        match class {
            Class::Answering | Class::TimeSensitive => Route::Now,
            Class::Proactive => {
                if user_active && self.cards_on(day) < self.tuned.daily_cap.clamp(1,5) {
                    self.cards_today += 1;
                    Route::Now
                } else {
                    Route::Hold
                }
            }
        }
    }

    pub fn note_suggest(&mut self, names: &[String]) {
        for n in names {
            if !self.suggest.contains(n) {
                self.suggest.push(n.clone());
            }
        }
    }

    pub fn note(&mut self, t: Text) {
        self.notes.push(t);
    }
}

/// What a card is to the budget.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Class {
    /// Something the user is waiting on or just asked for: an approval First
    /// Mate needs while the user spoke this turn, the per-worktree cards
    /// after "Let me pick", a level the user wrote by hand (D12), the
    /// inventory (D6). Up at once, not counted.
    Answering,
    /// First Mate's own initiative: the sweep's batch, promotion offers,
    /// a rule's approval or a proposal when the user said nothing. Counted
    /// against the cap; up now only while the user is active.
    Proactive,
    /// A rule's approval that cannot wait for the brief (a CI failure's):
    /// up at once whether the user is there or not, not counted. Every
    /// First Mate card reaches Telegram through seahelm-gateway as it goes up.
    TimeSensitive,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    Now,
    Hold,
}

/// The brief day a moment belongs to: the local date, `DAY_STARTS_AT` back.
pub fn brief_day(now: f64, offset: i64) -> String {
    Local::with_offset(now - tuning::DAY_STARTS_AT as f64 * 60.0, offset).day_key()
}

/// When the brief day containing `now` started (unix seconds).
pub fn brief_day_start(now: f64, offset: i64) -> f64 {
    let shift = tuning::DAY_STARTS_AT as f64 * 60.0;
    let local = now + offset as f64 - shift;
    (local / 86_400.0).floor() * 86_400.0 + shift - offset as f64
}

/// Where the user will see it: Telegram when that is where they just
/// arrived; the island when a desktop client is in front; Telegram when they
/// have been answering there (more recently than on the web); otherwise the
/// timeline only.
pub fn channel(p: &Snapshot, arrival: Option<&presence::Arrival>, now: f64) -> BriefChannel {
    if arrival.and_then(|a| a.channel) == Some(Channel::Telegram) {
        return BriefChannel::Telegram;
    }
    if p.desktop_in_front {
        return BriefChannel::Island;
    }
    let tg = p.profile.seen_on(Channel::Telegram);
    if tg > 0.0 && now - tg <= tuning::TELEGRAM_RECENT && tg >= p.profile.seen_on(Channel::Web) {
        return BriefChannel::Telegram;
    }
    BriefChannel::Island
}

/// Whether the brief is due now. Never in quiet hours (`quiet`), never
/// twice a brief day. On arrival: the first time the user is active after a
/// gap, this brief day. Fallback: no signal at all this brief day by the
/// usual start + `FALLBACK_AFTER`.
pub fn due(s: &State, p: &Snapshot, now: f64, offset: i64, quiet: bool) -> Option<Due> {
    if quiet {
        return None;
    }
    let day = brief_day(now, offset);
    if s.brief_day == day {
        return None;
    }
    let start = brief_day_start(now, offset);
    if let Some(a) = &p.profile.last_arrival {
        if a.at >= start && a.at > s.last_brief_at && p.active(now) {
            return Some(Due::Arrival(channel(p, Some(a), now)));
        }
    }
    if p.profile.last_seen >= start {
        // Seen today, but the arrival is not (or no longer) fresh: wait for
        // the next one.
        return None;
    }
    let weekday = presence::weekday(presence::day_number(start, offset));
    let usual = p.profile.usual_start(weekday)? as f64 * 60.0;
    // The start is a minute of the calendar day; before DAY_STARTS_AT it is
    // past midnight, in the next calendar day of this brief day.
    let midnight = start - tuning::DAY_STARTS_AT as f64 * 60.0;
    let usual_at = if usual < tuning::DAY_STARTS_AT as f64 * 60.0 { midnight + 86_400.0 + usual } else { midnight + usual };
    (now >= usual_at + tuning::FALLBACK_AFTER).then_some(Due::Fallback)
}

/// When each raised card went up, for expiry. In memory: First Mate's
/// cards do not outlive the core either.
#[derive(Debug, Default)]
pub struct Expiry {
    raised: HashMap<String, f64>,
}

impl Expiry {
    pub fn raised(&mut self, payload: &str, now: f64) {
        self.raised.insert(payload.to_string(), now);
    }

    pub fn forget(&mut self, payload: &str) {
        self.raised.remove(payload);
    }

    pub fn clear(&mut self) {
        self.raised.clear();
    }

    /// Payloads up for `CARD_EXPIRY` or longer, oldest first; forgotten.
    pub fn age(&self, payload: &str, now: f64) -> Option<f64> { self.raised.get(payload).map(|at| (now - at).max(0.0)) }
    pub fn take_due(&mut self, now: f64) -> Vec<String> { self.take_due_after(now, tuning::CARD_EXPIRY) }
    pub fn take_due_after(&mut self, now: f64, expiry: f64) -> Vec<String> {
        let mut due: Vec<(String, f64)> = self.raised.iter().filter(|(_, at)| now - **at >= expiry).map(|(p, at)| (p.clone(), *at)).collect();
        due.sort_by(|a, b| a.1.total_cmp(&b.1));
        for (p, _) in &due {
            self.raised.remove(p);
        }
        due.into_iter().map(|(p, _)| p).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::first_mate::presence::{Arrival, Profile};

    /// 2026-11-02 00:00 UTC, a Monday.
    const MONDAY: f64 = 1_793_577_600.0;
    const H: f64 = 3600.0;
    const DAY: f64 = 86_400.0;

    fn snap(profile: Profile, front: bool) -> Snapshot {
        Snapshot { profile, desktop_in_front: front }
    }

    /// Three weeks of Mondays starting at 09:00, then quiet until `last`.
    fn learned() -> Profile {
        let mut p = Profile::default();
        for w in 0..3 {
            let m = MONDAY + w as f64 * 7.0 * DAY;
            p.record(m + 9.0 * H, 0, Some(Channel::Desktop));
            p.record(m + 12.0 * H, 0, Some(Channel::Desktop));
        }
        p
    }

    #[test]
    fn the_brief_day_starts_at_four() {
        assert_eq!(brief_day(MONDAY + 3.0 * H, 0), "2026-11-01", "03:00 is still Sunday's");
        assert_eq!(brief_day(MONDAY + 5.0 * H, 0), "2026-11-02");
        assert_eq!(brief_day_start(MONDAY + 3.0 * H, 0), MONDAY - DAY + 4.0 * H);
        assert_eq!(brief_day_start(MONDAY + 23.0 * H, 0), MONDAY + 4.0 * H);
        // UTC+8: 01:00 local Tuesday is 17:00 UTC Monday, still Monday's brief day.
        assert_eq!(brief_day(MONDAY + 17.0 * H, 8 * 3600), "2026-11-02");
        assert_eq!(brief_day_start(MONDAY + 17.0 * H, 8 * 3600), MONDAY + 4.0 * H - 8.0 * H);
    }

    #[test]
    fn arrival_sends_once_a_day() {
        let mut p = learned();
        let today = MONDAY + 21.0 * DAY;
        p.record(today - DAY + 22.0 * H, 0, Some(Channel::Desktop));
        assert!(p.record(today + 8.0 * H, 0, Some(Channel::Desktop)).is_some(), "ten hours away");
        let mut s = State::default();
        let now = today + 8.0 * H + 60.0;
        assert_eq!(due(&s, &snap(p.clone(), true), now, 0, false), Some(Due::Arrival(BriefChannel::Island)));
        assert_eq!(due(&s, &snap(p.clone(), true), now, 0, true), None, "never in quiet hours");
        s.dealt_with(&brief_day(now, 0), Some(now));
        assert_eq!(due(&s, &snap(p.clone(), true), now + 60.0, 0, false), None);
        // Away again over lunch for five hours: still today, no second brief.
        p.record(today + 14.0 * H, 0, Some(Channel::Desktop));
        assert!(p.record(today + 19.5 * H, 0, Some(Channel::Desktop)).is_some());
        assert_eq!(due(&s, &snap(p.clone(), true), today + 19.5 * H, 0, false), None);
        // Tomorrow's arrival is a new day.
        p.record(today + DAY + 9.0 * H, 0, Some(Channel::Desktop));
        assert!(due(&s, &snap(p, true), today + DAY + 9.0 * H, 0, false).is_some());
    }

    #[test]
    fn an_arrival_in_quiet_hours_waits_while_the_user_is_still_there() {
        let mut p = learned();
        let today = MONDAY + 21.0 * DAY;
        p.record(today - DAY + 20.0 * H, 0, None);
        p.record(today + 6.5 * H, 0, None); // arrives 06:30, quiet until 07:00
        let s = State::default();
        assert_eq!(due(&s, &snap(p.clone(), true), today + 6.5 * H, 0, true), None);
        // Still at it at 07:05: the arrival stands.
        p.record(today + 7.0 * H, 0, None);
        assert!(due(&s, &snap(p.clone(), true), today + 7.0 * H + 300.0, 0, false).is_some());
        // Gone again by then: waits for them.
        assert_eq!(due(&s, &snap(p, true), today + 7.0 * H + tuning::ACTIVE_WINDOW + 60.0, 0, false), None);
    }

    #[test]
    fn channel_follows_where_the_user_is() {
        let mut p = learned();
        let now = MONDAY + 21.0 * DAY + 9.0 * H;
        let at_desk = Arrival { at: now, away: Some(10.0 * H), channel: Some(Channel::Desktop) };
        assert_eq!(channel(&snap(p.clone(), true), Some(&at_desk), now), BriefChannel::Island);
        // No client in front and never answered on Telegram: the timeline.
        assert_eq!(channel(&snap(p.clone(), false), Some(&at_desk), now), BriefChannel::Island);
        // Answers on Telegram lately: there.
        p.record(now - 2.0 * DAY, 0, Some(Channel::Telegram));
        assert_eq!(channel(&snap(p.clone(), false), Some(&at_desk), now), BriefChannel::Telegram);
        // …unless the web is more recent.
        p.record(now - DAY, 0, Some(Channel::Web));
        assert_eq!(channel(&snap(p.clone(), false), Some(&at_desk), now), BriefChannel::Island);
        // Arriving on Telegram wins even with the app left in front.
        let on_phone = Arrival { channel: Some(Channel::Telegram), ..at_desk };
        assert_eq!(channel(&snap(p.clone(), true), Some(&on_phone), now), BriefChannel::Telegram);
        // Telegram answers a month old do not count.
        let mut old = learned();
        old.record(now - 30.0 * DAY, 0, Some(Channel::Telegram));
        assert_eq!(channel(&snap(old, false), None, now), BriefChannel::Island);
    }

    #[test]
    fn fallback_goes_to_telegram_once_by_the_usual_start_plus_an_hour() {
        let mut p = learned();
        let today = MONDAY + 21.0 * DAY; // a Monday; usual start 09:00
        p.record(today - 2.0 * DAY, 0, None); // last seen Saturday
        let mut s = State::default();
        assert_eq!(due(&s, &snap(p.clone(), false), today + 9.5 * H, 0, false), None, "not yet an hour late");
        assert_eq!(due(&s, &snap(p.clone(), false), today + 10.0 * H, 0, false), Some(Due::Fallback));
        assert_eq!(Due::Fallback.channel(), BriefChannel::Telegram);
        assert_eq!(due(&s, &snap(p.clone(), false), today + 10.0 * H, 0, true), None, "not in quiet hours either");
        s.dealt_with(&brief_day(today + 10.0 * H, 0), Some(today + 10.0 * H));
        assert_eq!(due(&s, &snap(p.clone(), false), today + 15.0 * H, 0, false), None, "once");
        // Arriving later that day sends nothing more.
        p.record(today + 16.0 * H, 0, Some(Channel::Desktop));
        assert_eq!(due(&s, &snap(p.clone(), true), today + 16.0 * H, 0, false), None);
        // Seen today already (before the usual start): no fallback.
        let mut q = learned();
        q.record(today - 2.0 * DAY, 0, None);
        q.record(today + 5.0 * H, 0, None);
        assert_eq!(due(&State::default(), &snap(q.clone(), false), today + 11.0 * H, 0, false), None, "seen at 05:00, gone by 11:00: waits for the next arrival");
        // A profile that knows nothing never falls back.
        let mut blank = Profile::default();
        blank.record(today - 3.0 * DAY, 0, None);
        assert_eq!(due(&State::default(), &snap(blank, false), today + 20.0 * H, 0, false), None);
    }

    #[test]
    fn the_cap_holds_proactive_cards_and_spares_answers() {
        let mut s = State::default();
        let day = "2026-11-23";
        assert_eq!(s.route(Class::Proactive, day, false), Route::Hold, "the user is away: waits for the brief");
        for _ in 0..tuning::DAILY_CARD_CAP {
            assert_eq!(s.route(Class::Proactive, day, true), Route::Now);
        }
        assert_eq!(s.route(Class::Proactive, day, true), Route::Hold, "over the cap");
        assert_eq!(s.route(Class::Answering, day, true), Route::Now, "answering the user is not counted");
        assert_eq!(s.route(Class::Answering, day, false), Route::Now);
        assert_eq!(s.route(Class::TimeSensitive, day, false), Route::Now, "a CI failure's approval: now, away or not");
        assert_eq!(s.cards_today, tuning::DAILY_CARD_CAP);
        assert_eq!(s.route(Class::Proactive, "2026-11-24", true), Route::Now, "a new day");
        assert_eq!(s.cards_today, 1);
    }

    #[test]
    fn cards_expire_after_three_days() {
        let mut e = Expiry::default();
        e.raised("a", 100.0);
        e.raised("b", 200.0);
        e.raised("c", 300.0);
        e.forget("c");
        assert!(e.take_due(100.0 + tuning::CARD_EXPIRY - 1.0).is_empty());
        assert_eq!(e.take_due(200.0 + tuning::CARD_EXPIRY), vec!["a", "b"]);
        assert!(e.take_due(1e12).is_empty(), "taken once");
    }

    #[test]
    fn state_round_trips_and_a_sent_brief_spends_the_suggestions() {
        let tmp = tempfile::tempdir().unwrap();
        let path = State::path(tmp.path());
        let mut s = State::default();
        s.note_suggest(&["a".to_string()]);
        s.note_suggest(&["a".to_string(), "b".to_string()]);
        assert_eq!(s.suggest, vec!["a", "b"]);
        s.note(Text::new("Habit h down", "习惯 h 降"));
        s.save(&path);
        assert_eq!(State::load(&path), s);
        s.dealt_with("2026-11-02", None);
        assert_eq!(s.suggest.len(), 2, "nothing was sent");
        s.dealt_with("2026-11-03", Some(5.0));
        assert!(s.suggest.is_empty() && s.notes.is_empty());
        assert_eq!((s.brief_day.as_str(), s.last_brief_at), ("2026-11-03", 5.0));
    }

    #[test]
    fn a_brief_for_telegram_needs_telegram() {
        let arrival = Due::Arrival(BriefChannel::Telegram);
        assert_eq!(arrival.settle(true), Some(BriefChannel::Telegram));
        assert_eq!(arrival.settle(false), Some(BriefChannel::Island), "the timeline has it; the user reads it there");
        assert_eq!(Due::Fallback.settle(true), Some(BriefChannel::Telegram));
        assert_eq!(Due::Fallback.settle(false), None, "not sent, not counted: it waits for the user to come back");
        assert_eq!(Due::Arrival(BriefChannel::Island).settle(false), Some(BriefChannel::Island));
    }
}
