//! The daily brief and the rest of the interruption budget on First Mate's
//! side (docs/first-mate-autonomy.md, "Interruption budget", phase 5).
//!
//! The brief is the core's, not the model's: composed from the audit log,
//! the cards and the sweep's `suggest` lines, with no turn and no tokens,
//! and written into First Mate's timeline as a `brief` row. When it goes to
//! Telegram the core also publishes `first_mate.brief {text, channel}`,
//! which seahelm-gateway sends to the default chat. Nothing to say, no
//! brief.
//!
//! Cards: every card First Mate raises goes through `put_card`, which puts
//! it up now or holds it for the brief (`budget::State::route`); the brief
//! puts everything held up with it. A card up for `CARD_EXPIRY` is
//! withdrawn (`expire_cards`): a `card.expired` observation, an `ignored`
//! in its habit's evidence (two in a row take the habit down,
//! `Book::expired`).

use std::collections::HashSet;
use std::path::Path;

use serde_json::{json, Value};

use seahelm_core_registry::cards::{CardKind, Raise};

use super::budget::{self, BriefChannel, Class, Due, Route};
use super::engine::{iso8601, Entry};
use super::habits::HabitLevel;
use super::{observations, pane, FirstMate};

/// What goes into a brief.
#[derive(Clone, Debug, Default)]
pub struct Inputs {
    /// How long the user was away, when the brief meets an arrival.
    pub away: Option<f64>,
    /// Sent because the user had not arrived by their usual start.
    pub fallback: bool,
    /// The audit since the last brief.
    pub entries: Vec<Entry>,
    /// The first line of each First Mate card waiting on the user, up or
    /// held for this brief.
    pub waiting: Vec<String>,
    /// The sweep's `suggest` lines since the last brief.
    pub suggest: Vec<String>,
}

fn listed(items: &[String]) -> String {
    let n = budget::tuning::BRIEF_LISTED;
    let mut s = items.iter().take(n).cloned().collect::<Vec<_>>().join(" · ");
    if items.len() > n {
        s += &format!(" · +{} more", items.len() - n);
    }
    s
}

fn hours(secs: f64) -> String {
    let h = (secs / 3600.0).round() as i64;
    if h >= 48 {
        format!("{} days", h / 24)
    } else {
        format!("{} h", h.max(1))
    }
}

fn base_name(path: &str) -> String {
    Path::new(path).file_name().and_then(|n| n.to_str()).unwrap_or(path).to_string()
}

/// The brief's text: a title line, then one line per section that has
/// something — done, waiting on you, could go, notes. None when every
/// section is empty.
pub fn compose(i: &Inputs) -> Option<String> {
    let actions: Vec<&Entry> = i.entries.iter().filter(|e| e.kind == "action").collect();
    let by_habit: Vec<String> = actions
        .iter()
        .filter(|e| e.rule.as_deref().is_some_and(|r| r.starts_with("habit:")) && e.level.as_deref() == Some("auto"))
        .map(|e| e.worktree_path.as_deref().map(base_name).unwrap_or_else(|| e.text.clone()))
        .collect();
    let others: Vec<String> = actions
        .iter()
        .filter(|e| !(e.rule.as_deref().is_some_and(|r| r.starts_with("habit:")) && e.level.as_deref() == Some("auto")))
        .map(|e| match e.level.as_deref() {
            Some("auto") => format!("{} (on my own)", e.text),
            Some(l @ ("approved" | "picked")) => format!("{} ({l} by you)", e.text),
            _ => e.text.clone(),
        })
        .collect();
    let mut done = Vec::new();
    if !by_habit.is_empty() {
        let n = by_habit.len();
        done.push(format!("deleted {n} worktree{} by habit — {}", if n == 1 { "" } else { "s" }, listed(&by_habit)));
    }
    if !others.is_empty() {
        done.push(listed(&others));
    }
    let changes: Vec<String> = i.entries.iter().filter(|e| e.kind == "habit" && e.text.starts_with("Habit ")).map(|e| e.text.clone()).collect();
    let expired = i.entries.iter().filter(|e| e.kind == "expired").count();
    let mut notes = changes;
    if expired > 0 {
        notes.push(format!("{expired} card{} withdrawn unanswered after {} days", if expired == 1 { "" } else { "s" }, (budget::tuning::CARD_EXPIRY / 86_400.0).round()));
    }
    if done.is_empty() && i.waiting.is_empty() && i.suggest.is_empty() && notes.is_empty() {
        return None;
    }
    let title = match (i.away, i.fallback) {
        (_, true) => "First Mate · daily brief (you have not been at the desk today)".to_string(),
        (Some(a), false) => format!("First Mate · daily brief · away {}", hours(a)),
        (None, false) => "First Mate · daily brief".to_string(),
    };
    let mut out = vec![title];
    if !done.is_empty() {
        out.push(format!("Done: {}", done.join("; ")));
    }
    if !i.waiting.is_empty() {
        let n = i.waiting.len();
        out.push(format!("Waiting on you ({n} card{}): {}", if n == 1 { "" } else { "s" }, listed(&i.waiting)));
    }
    if !i.suggest.is_empty() {
        out.push(format!("Could go (no card): {}", i.suggest.join(" ")));
    }
    if !notes.is_empty() {
        out.push(format!("Notes: {}", notes.join(" · ")));
    }
    Some(out.join("\n"))
}

/// A card First Mate holds for the brief.
#[derive(Clone, Debug, PartialEq)]
pub struct Held {
    pub kind: CardKind,
    pub payload: String,
    pub message: String,
    pub options: Vec<String>,
}

impl Held {
    fn headline(&self) -> String {
        self.message.lines().next().unwrap_or_default().trim_start_matches("First Mate: ").to_string()
    }
}

fn offset(now: f64) -> i64 {
    crate::usage::local_offset(now)
}

impl FirstMate {
    fn save_budget(&self) {
        self.budget.save(&budget::State::path(&self.dir));
    }

    pub(super) fn user_active(&self, now: f64) -> bool {
        self.core.presence().active(now)
    }

    /// One of First Mate's cards: up now, or held for the brief (`route`).
    pub(super) fn put_card(&mut self, kind: CardKind, payload: &str, message: String, options: Vec<String>, class: Class, now: f64) {
        let held = Held { kind, payload: payload.into(), message, options };
        let day = budget::brief_day(now, offset(now));
        let active = self.user_active(now);
        match self.budget.route(class, &day, active) {
            Route::Now => self.raise_now(held, now),
            Route::Hold => {
                let why = if active { "today's proactive cards are used up" } else { "the user is away" };
                self.log(Entry::new(now, "held", format!("{} — held for the brief ({why})", held.headline())));
                self.held.retain(|h| h.payload != held.payload);
                self.held.push(held);
            }
        }
        self.save_budget();
    }

    fn raise_now(&mut self, h: Held, now: f64) {
        self.core.raise_card(Raise {
            kind: Some(h.kind),
            worktree_path: self.dir.to_string_lossy().into(),
            project: pane::PROJECT.into(),
            message: h.message,
            options: h.options,
            payload: Some(h.payload.clone()),
            ..Raise::default()
        });
        self.expiry.raised(&h.payload, now);
    }

    /// Take a card down, up or held.
    pub(super) fn withdraw(&mut self, payload: &str) {
        self.core.drop_card_payload(payload);
        self.held.retain(|h| h.payload != payload);
        self.expiry.forget(payload);
    }

    /// The user is back after today's brief (or there was none to send):
    /// held cards go up, as many as the cap still allows.
    pub(super) fn release_held(&mut self, now: f64) {
        if self.held.is_empty() || self.config.paused || !self.user_active(now) {
            return;
        }
        let day = budget::brief_day(now, offset(now));
        while !self.held.is_empty() {
            if self.budget.route(Class::Proactive, &day, true) == Route::Hold {
                break;
            }
            let h = self.held.remove(0);
            self.raise_now(h, now);
        }
        self.save_budget();
    }

    /// The brief, when it is due (`budget::due`). Never while paused; quiet
    /// hours are any known repo's (the brief is about all of them).
    pub(super) fn maybe_brief(&mut self, now: f64) {
        if self.config.paused {
            return;
        }
        let presence = self.core.presence();
        let off = offset(now);
        let Some(due) = budget::due(&self.budget, &presence, now, off, false) else { return };
        if self.any_quiet_hours(now) {
            return;
        }
        let away = match due {
            Due::Arrival(_) => presence.profile.last_arrival.as_ref().and_then(|a| a.away),
            Due::Fallback => None,
        };
        self.send_brief(due, away, now);
    }

    fn any_quiet_hours(&mut self, now: f64) -> bool {
        let local = super::clock::Local::at(now);
        self.core.repos().iter().any(|r| self.config_for(r).ok().and_then(|c| c.settings.quiet_hours).is_some_and(|q| q.contains(&local)))
    }

    /// What the cards waiting on the user say: those up, then those held.
    fn waiting_lines(&self) -> Vec<String> {
        let mut out: Vec<String> = self
            .core
            .cards_with_payloads(|p| self.is_first_mates(p))
            .iter()
            .filter_map(|c| c.get("message").and_then(Value::as_str))
            .map(|m| m.lines().next().unwrap_or_default().trim_start_matches("First Mate: ").to_string())
            .collect();
        out.extend(self.held.iter().map(Held::headline));
        out
    }

    fn is_first_mates(&self, payload: &str) -> bool {
        self.approvals.contains_key(payload) || self.proposals.contains_key(payload) || self.is_habit_card(payload)
    }

    pub(super) fn send_brief(&mut self, due: Due, away: Option<f64>, now: f64) {
        let day = budget::brief_day(now, offset(now));
        let since = if self.budget.last_brief_at > 0.0 { self.budget.last_brief_at } else { now - 86_400.0 };
        let since_iso = iso8601(since);
        let entries: Vec<Entry> = self.audit.recent(5000).into_iter().filter(|e| e.at > since_iso).collect();
        let inputs = Inputs { away, fallback: due == Due::Fallback, entries, waiting: self.waiting_lines(), suggest: self.budget.suggest.clone() };
        let Some(text) = compose(&inputs) else {
            self.budget.dealt_with(&day, None);
            self.save_budget();
            return;
        };
        let channel = due.channel();
        self.core.first_mate_brief(&text);
        if channel == BriefChannel::Telegram {
            self.core.publish_event(json!({"type": "first_mate.brief", "text": text, "channel": channel.as_str()}));
        }
        let why = match due {
            Due::Arrival(_) => "on arrival",
            Due::Fallback => "not arrived by the usual start",
        };
        self.log(Entry::new(now, "brief", format!("daily brief to {} ({why}) — {}", channel.as_str(), text.replace('\n', " / "))));
        // What waited for the brief goes up with it, uncounted.
        for h in std::mem::take(&mut self.held) {
            self.raise_now(h, now);
        }
        self.budget.dealt_with(&day, Some(now));
        self.save_budget();
    }

    // MARK: expiry

    /// Withdraw First Mate's cards unanswered for `CARD_EXPIRY`.
    pub(super) fn expire_cards(&mut self, now: f64) {
        for payload in self.expiry.take_due(now) {
            if self.core.has_card_payload(&payload) {
                self.expire(&payload, now);
            }
        }
    }

    fn expire(&mut self, payload: &str, now: f64) {
        self.core.drop_card_payload(payload);
        let today = super::clock::Local::at(now).day_key();
        let s = |p: &Value, k: &str| p.get(k).and_then(Value::as_str).unwrap_or_default().to_string();
        let mut habits: Vec<(String, String)> = Vec::new();
        let (kind, summary, worktree, repo) = if let Some(a) = self.approvals.remove(payload) {
            if a.action == super::rules::Action::DeleteWorktree {
                habits.extend(self.delete_habit_of(&a.params, now));
            }
            ("approval", a.summary, s(&a.params, "worktree_path"), s(&a.params, "repo_path"))
        } else if let Some(p) = self.proposals.remove(payload) {
            ("proposal", p.summary, String::new(), String::new())
        } else if let Some(b) = self.batches.remove(payload) {
            let mut seen = HashSet::new();
            for r in &b.items {
                if seen.insert((r.decision.key.clone(), r.decision.id.clone())) {
                    habits.push((r.decision.key.clone(), r.decision.id.clone()));
                }
            }
            let items: Vec<String> = self.items.iter().filter(|(_, (bp, _))| bp == payload).map(|(p, _)| p.clone()).collect();
            for p in items {
                self.items.remove(&p);
                self.withdraw(&p);
            }
            ("habit.sweep", b.card().0.lines().next().unwrap_or_default().to_string(), String::new(), String::new())
        } else if let Some((bp, i)) = self.items.remove(payload) {
            // Picked one by one: the user engaged with the batch; no evidence.
            let mut name = String::new();
            if let Some(b) = self.batches.get_mut(&bp) {
                b.open.retain(|x| *x != i);
                name = b.items.get(i).map(|r| r.candidate.name()).unwrap_or_default();
                if b.open.is_empty() {
                    self.batches.remove(&bp);
                }
            }
            ("habit.item", format!("delete worktree {name}"), String::new(), String::new())
        } else if let Some(o) = self.offers.withdraw(payload) {
            habits.push((o.key.clone(), o.id.clone()));
            if o.confirm {
                // Not asked again until the file says something else.
                self.expired_confirms.insert((o.key.clone(), o.id.clone(), o.level));
            } else {
                // Like a "not yet": the next offer waits for fresh evidence.
                let mut b = self.habits.load(&o.key, &today);
                b.declined(&o.id);
                self.save_book(&b, now);
            }
            (if o.confirm { "habit.confirm" } else { "habit.promote" }, format!("{} habit {} to {}", if o.confirm { "confirm" } else { "promote" }, o.id, o.level.as_str()), String::new(), String::new())
        } else if let Some(c) = self.inventory.withdraw(payload) {
            ("habit.inventory", format!("inventory: {}", c.group.title()), String::new(), String::new())
        } else {
            return;
        };
        for (key, id) in &habits {
            let mut b = self.habits.load(key, &today);
            let change = b.expired(id);
            self.save_book(&b, now);
            if let Some(c) = change {
                self.report_change(&c, now);
            }
        }
        let habit = (!habits.is_empty()).then(|| habits.iter().map(|(k, i)| format!("{k}/{i}")).collect::<Vec<_>>().join(","));
        self.core.observe(observations::Msg::CardExpired { card_kind: kind, card: payload.into(), summary: summary.clone(), worktree, repo, habit });
        let days = (budget::tuning::CARD_EXPIRY / 86_400.0).round();
        self.log(Entry::new(now, "expired", format!("withdrawn unanswered after {days} days: {summary}")));
    }

    /// A hand-raised level whose confirmation card expired is not asked
    /// about again while the file still says the same.
    pub(super) fn confirm_expired(&self, key: &str, id: &str, level: HabitLevel) -> bool {
        self.expired_confirms.contains(&(key.to_string(), id.to_string(), level))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn action(text: &str, rule: Option<&str>, level: &str, wt: Option<&str>) -> Entry {
        let mut e = Entry::new(1.0, "action", text);
        e.rule = rule.map(str::to_string);
        e.level = Some(level.into());
        e.worktree_path = wt.map(str::to_string);
        e
    }

    #[test]
    fn nothing_to_say_is_no_brief() {
        assert_eq!(compose(&Inputs::default()), None);
        // Audit lines that are not news (events, deliveries, held cards) say nothing.
        let quiet = Inputs {
            away: Some(10.0 * 3600.0),
            entries: vec![Entry::new(1.0, "event", "pr.merged · x"), Entry::new(1.0, "delivered", "handed to First Mate"), Entry::new(1.0, "held", "x — held"), Entry::new(1.0, "habit", "Inventory: …")],
            ..Inputs::default()
        };
        assert_eq!(compose(&quiet), None);
    }

    #[test]
    fn the_brief_reads_done_waiting_could_go_notes() {
        let i = Inputs {
            away: Some(13.0 * 3600.0),
            fallback: false,
            entries: vec![
                action("Deleted worktree a by habit h — …", Some("habit:delete-merged-clean"), "auto", Some("/w/wt/feat-a")),
                action("Deleted worktree b by habit h — …", Some("habit:delete-merged-clean"), "auto", Some("/w/wt/feat-b")),
                action("sent to #7: fix CI", None, "auto", None),
                action("Deleted worktree c (approved, habit h)", None, "approved", Some("/w/wt/c")),
                Entry::new(1.0, "habit", "Habit closed-idle down from ask to suggest: two of its cards went unanswered"),
                Entry::new(1.0, "expired", "withdrawn unanswered after 3 days: …"),
            ],
            waiting: vec!["these 2 worktrees look done:".into()],
            suggest: vec!["These look done: spike-x.".into()],
        };
        let text = compose(&i).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[0], "First Mate · daily brief · away 13 h");
        assert_eq!(lines[1], "Done: deleted 2 worktrees by habit — feat-a · feat-b; sent to #7: fix CI (on my own) · Deleted worktree c (approved, habit h) (approved by you)");
        assert_eq!(lines[2], "Waiting on you (1 card): these 2 worktrees look done:");
        assert_eq!(lines[3], "Could go (no card): These look done: spike-x.");
        assert_eq!(lines[4], "Notes: Habit closed-idle down from ask to suggest: two of its cards went unanswered · 1 card withdrawn unanswered after 3 days");
        assert_eq!(lines.len(), 5);
    }

    #[test]
    fn long_lists_are_cut_and_the_fallback_says_why() {
        let names: Vec<Entry> = (0..8).map(|n| action("x", Some("habit:h"), "auto", Some(&format!("/w/wt-{n}")))).collect();
        let text = compose(&Inputs { fallback: true, entries: names, ..Inputs::default() }).unwrap();
        assert!(text.starts_with("First Mate · daily brief (you have not been at the desk today)\n"), "{text}");
        assert!(text.contains("deleted 8 worktrees by habit — wt-0 · wt-1 · wt-2 · wt-3 · wt-4 · +3 more"), "{text}");
        let days = compose(&Inputs { away: Some(3.0 * 86_400.0), waiting: vec!["x".into()], ..Inputs::default() }).unwrap();
        assert!(days.starts_with("First Mate · daily brief · away 3 days"), "{days}");
    }

    // MARK: First Mate's side, over a scratch core

    use std::sync::Arc;

    use crate::core::Core;
    use crate::rpc::Dispatch;
    use crate::first_mate::habits::{self as hb, GLOBAL, SEED_ID};
    use crate::first_mate::presence::Channel;
    use crate::first_mate::sweep::{Batch, Candidate, Routed};

    fn first_mate(tmp: &Path) -> (Arc<Core>, FirstMate) {
        let core = Core::for_test(tmp);
        let dir = tmp.join("first-mate");
        std::fs::create_dir_all(&dir).unwrap();
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut fm = FirstMate::new(core.clone(), tx, dir.clone(), dir.join("habits"));
        fm.running = true;
        core.ensure_first_mate_pane(&dir.to_string_lossy());
        (core, fm)
    }

    fn routed(name: &str) -> Routed {
        let facts = super::super::facts::Facts { pr: Some("merged".into()), unpushed: Some(0), idle_days: Some(3), ..Default::default() };
        let candidate = Candidate { path: format!("/nonexistent/wt/{name}"), repo: "/nonexistent/repo".into(), branch: format!("feat/{name}"), facts };
        Routed { candidate, decision: hb::Decision { key: GLOBAL.into(), id: SEED_ID.into(), level: HabitLevel::Ask } }
    }

    fn sweep_card(fm: &mut FirstMate, nonce: &str, now: f64) -> String {
        let b = Batch::new(nonce, vec![routed("a"), routed("b")]);
        let (m, o) = b.card();
        let p = b.payload.clone();
        fm.batches.insert(p.clone(), b);
        fm.put_card(CardKind::Approval, &p, m, o, Class::Proactive, now);
        p
    }

    fn seed_level(fm: &FirstMate, today: &str) -> (HabitLevel, u32, u32) {
        let b = fm.habits.load(GLOBAL, today);
        let h = b.get(SEED_ID).unwrap();
        (b.level(h), h.evidence.ignored, h.evidence.expired_in_row)
    }

    fn audit_kinds(fm: &FirstMate) -> Vec<String> {
        fm.audit.recent(500).into_iter().map(|e| e.kind).collect()
    }

    #[test]
    fn an_expired_card_is_withdrawn_counted_as_ignored_and_twice_demotes() {
        let tmp = tempfile::tempdir().unwrap();
        let (core, mut fm) = first_mate(tmp.path());
        let now = seahelm_core_types::now();
        let today = super::super::clock::Local::at(now).day_key();
        fm.habits.ensure_seed(&today, now).unwrap();
        core.presence_signal(now, Some(Channel::Desktop));

        let first = sweep_card(&mut fm, "s1", now);
        assert!(core.has_card_payload(&first));
        fm.expire_cards(now + budget::tuning::CARD_EXPIRY - 60.0);
        assert!(core.has_card_payload(&first), "not yet");
        fm.expire_cards(now + budget::tuning::CARD_EXPIRY);
        assert!(!core.has_card_payload(&first), "withdrawn");
        assert!(!fm.batches.contains_key(&first));
        assert_eq!(seed_level(&fm, &today), (HabitLevel::Ask, 1, 1), "one batch, one ignored, however many worktrees");
        assert!(audit_kinds(&fm).contains(&"expired".to_string()));

        // An approval in between would reset the run; a second expiry in a row demotes.
        let later = now + budget::tuning::CARD_EXPIRY + 60.0;
        core.presence_signal(later, Some(Channel::Desktop));
        let second = sweep_card(&mut fm, "s2", later);
        fm.expire_cards(later + budget::tuning::CARD_EXPIRY);
        assert!(!core.has_card_payload(&second));
        let (level, ignored, in_row) = seed_level(&fm, &today);
        assert_eq!((level, ignored, in_row), (HabitLevel::Suggest, 2, 0), "two in a row: down one level, the run starts over");
        let lines: Vec<String> = fm.audit.recent(500).into_iter().filter(|e| e.kind == "habit").map(|e| e.text).collect();
        assert!(lines.iter().any(|l| l.contains("two of its cards went unanswered")), "{lines:?}");
    }

    #[test]
    fn expired_inventory_and_proposal_cards_teach_no_habit() {
        let tmp = tempfile::tempdir().unwrap();
        let (core, mut fm) = first_mate(tmp.path());
        let now = seahelm_core_types::now();
        let today = super::super::clock::Local::at(now).day_key();
        fm.habits.ensure_seed(&today, now).unwrap();
        let groups = vec![(super::super::inventory::Group::Merged, vec![routed("a").candidate])];
        let (cards, _) = fm.inventory.raise("i1", groups);
        let p = cards[0].payload.clone();
        let (m, o) = cards[0].render(1, 1);
        fm.put_card(CardKind::Approval, &p, m, o, Class::Answering, now);
        assert!(core.has_card_payload(&p), "the inventory goes up at once, even with nobody there");
        fm.expire_cards(now + budget::tuning::CARD_EXPIRY);
        assert!(!core.has_card_payload(&p) && !fm.inventory.contains(&p));
        assert_eq!(seed_level(&fm, &today), (HabitLevel::Ask, 0, 0));
    }

    #[test]
    fn the_cap_holds_the_fourth_proactive_card_and_the_brief_brings_it() {
        let tmp = tempfile::tempdir().unwrap();
        let (core, mut fm) = first_mate(tmp.path());
        let now = seahelm_core_types::now();
        let proactive = |fm: &mut FirstMate, n: &str| {
            let p = format!("proposal-{n}");
            fm.put_card(CardKind::Proposal, &p, format!("First Mate suggests: {n}"), vec!["Go".into(), "Not now".into()], Class::Proactive, now);
            p
        };
        // Away: even the first waits for the brief.
        let early = proactive(&mut fm, "early");
        assert!(!core.has_card_payload(&early));
        assert_eq!(fm.held.len(), 1);

        core.presence_signal(now, Some(Channel::Desktop));
        let up: Vec<String> = (0..budget::tuning::DAILY_CARD_CAP).map(|i| proactive(&mut fm, &i.to_string())).collect();
        assert!(up.iter().all(|p| core.has_card_payload(p)));
        let over = proactive(&mut fm, "over");
        assert!(!core.has_card_payload(&over), "over the cap");
        // The user's own request is never held or counted.
        fm.put_card(CardKind::Approval, "autopilot-mine", "First Mate asks: delete x".into(), vec!["Approve".into(), "Reject".into()], Class::Answering, now);
        assert!(core.has_card_payload("autopilot-mine"));
        // Back while the cap is spent: still held.
        fm.release_held(now);
        assert_eq!(fm.held.len(), 2);

        fm.send_brief(Due::Arrival(BriefChannel::Island), Some(10.0 * 3600.0), now);
        assert!(fm.held.is_empty());
        assert!(core.has_card_payload(&early) && core.has_card_payload(&over), "the brief brings what waited for it");
        let snapshot = core.clone().call("message.snapshot", serde_json::json!({"pane_id": super::super::policy::SESSION}));
        let crate::rpc::Reply::Value(Ok(v)) = snapshot else { panic!() };
        let brief = v["messages"].as_array().unwrap().iter().find(|m| m["kind"] == "brief").expect("a brief row").clone();
        let text = brief["text"].as_str().unwrap();
        assert!(text.starts_with("First Mate · daily brief · away 10 h\n"), "{text}");
        // (The cards up are raw here, not in First Mate's maps; the held ones are listed.)
        assert!(text.contains("Waiting on you (2 cards): First Mate suggests: early · First Mate suggests: over"), "{text}");
        assert_eq!(fm.budget.brief_day, budget::brief_day(now, offset(now)));
        assert!(audit_kinds(&fm).contains(&"brief".to_string()));
        // Saved: a restart does not send it again.
        assert_eq!(budget::State::load(&budget::State::path(&fm.dir)).brief_day, fm.budget.brief_day);
    }

    #[test]
    fn with_nothing_to_say_the_day_is_dealt_with_silently() {
        let tmp = tempfile::tempdir().unwrap();
        let (core, mut fm) = first_mate(tmp.path());
        let now = seahelm_core_types::now();
        fm.send_brief(Due::Fallback, None, now);
        let crate::rpc::Reply::Value(Ok(v)) = core.clone().call("message.snapshot", serde_json::json!({"pane_id": super::super::policy::SESSION})) else { panic!() };
        assert!(v["messages"].as_array().unwrap().iter().all(|m| m["kind"] != "brief"));
        assert_eq!(fm.budget.brief_day, budget::brief_day(now, offset(now)));
        assert_eq!(fm.budget.last_brief_at, 0.0, "nothing went out");
        assert!(!audit_kinds(&fm).contains(&"brief".to_string()));
    }

}
