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
//! puts up to `BRIEF_CARDS` held cards up with it and lists the rest. A
//! card up for `CARD_EXPIRY` is withdrawn (`expire_cards`): a
//! `card.expired` observation, and for an action card (a sweep batch, a
//! delete approval) an `ignored` in its habit's evidence (two in a row take
//! the habit down, `Book::expired`); a level offer just waits for fresh
//! evidence. Its text is in `first_mate_language` (`lang`).

use std::collections::HashSet;
use std::path::Path;

use serde_json::{json, Value};

use seahelm_core_registry::cards::{CardKind, Raise};

use super::budget::{self, BriefChannel, Class, Due, Route};
use super::engine::{iso8601, Entry};
use super::habits::HabitLevel;
use super::lang::{plural_en, Lang, Text};
use super::{observations, pane, FirstMate};

/// What goes into a brief.
#[derive(Clone, Debug, Default)]
pub struct Inputs {
    pub lang: Lang,
    /// How long the user was away, when the brief meets an arrival.
    pub away: Option<f64>,
    /// Sent because the user had not arrived by their usual start.
    pub fallback: bool,
    /// The audit since the last brief.
    pub entries: Vec<Entry>,
    /// The first line of each First Mate card waiting on the user, up or
    /// held.
    pub waiting: Vec<String>,
    /// Of those, the held ones that stay held after this brief (it puts up
    /// `BRIEF_CARDS` at most): listed, their cards later.
    pub later: usize,
    /// Worktrees the sweep found at `suggest` since the last brief.
    pub suggest: Vec<String>,
    pub tasks: Vec<String>,
    /// Habit level changes since the last brief.
    pub notes: Vec<Text>,
    pub research: Vec<String>,
}

fn listed(items: &[String], lang: Lang) -> String {
    let n = budget::tuning::BRIEF_LISTED;
    let mut s = items.iter().take(n).cloned().collect::<Vec<_>>().join(" · ");
    if items.len() > n {
        s += &match lang {
            Lang::En => format!(" · +{} more", items.len() - n),
            Lang::Zh => format!(" · 另 {} 项", items.len() - n),
        };
    }
    s
}

fn away(secs: f64, lang: Lang) -> String {
    let h = (secs / 3600.0).round() as i64;
    match (lang, h >= 48) {
        (Lang::En, true) => format!("away {} days", h / 24),
        (Lang::En, false) => format!("away {} h", h.max(1)),
        (Lang::Zh, true) => format!("离开了 {} 天", h / 24),
        (Lang::Zh, false) => format!("离开了 {} 小时", h.max(1)),
    }
}

/// One line, at most `DETAIL_CHARS` characters: what an action said or
/// started, as the brief quotes it.
const DETAIL_CHARS: usize = 60;

fn one_line(t: &str) -> String {
    let flat = t.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() > DETAIL_CHARS {
        format!("{}…", flat.chars().take(DETAIL_CHARS).collect::<String>())
    } else {
        flat
    }
}

/// An action First Mate asks for or took, in the user's language, from its
/// params (with `pane_id` already the pane as the user knows it, `#7 ·
/// feat-x`). None for an action without the params to say it.
pub fn describe_action(lang: Lang, action: super::rules::Action, params: &Value) -> Option<String> {
    use super::rules::Action;
    let s = |k: &str| params.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
    match action {
        Action::MessagePane => {
            let pane = s("pane_id")?;
            let what = s("command").or_else(|| s("text")).map(one_line).unwrap_or_default();
            Some(match lang {
                Lang::En => format!("tell {pane}: {what}"),
                Lang::Zh => format!("告诉 {pane}：{what}"),
            })
        }
        Action::StartAgent => {
            let repo = base_name(s("repo_path")?);
            let what = s("prompt").map(one_line).unwrap_or_default();
            Some(match lang {
                Lang::En => format!("start an agent in {repo}: {what}"),
                Lang::Zh => format!("在 {repo} 启动一个 agent：{what}"),
            })
        }
        Action::DeleteWorktree => {
            let wt = base_name(s("worktree_path")?);
            Some(match lang {
                Lang::En => format!("delete worktree {wt}"),
                Lang::Zh => format!("删除 worktree {wt}"),
            })
        }
    }
}

/// An audit line of an action, in the user's language, from its structured
/// fields (`FirstMate::annotate`). None for a line written before those
/// fields existed: the brief then quotes its text.
pub fn describe_entry(lang: Lang, e: &Entry) -> Option<String> {
    if e.kind == "research.started" {
        return Some(format!("{} {}", lang.pick("Started research under your schedule", "按你创建的调度启动调研"), e.detail.as_deref().unwrap_or_default()));
    }
    use super::rules::Action;
    let action = Action::parse(e.action.as_deref()?)?;
    let mut p = serde_json::Map::new();
    match action {
        Action::MessagePane => {
            p.insert("pane_id".into(), json!(e.pane.as_deref()?));
            p.insert("command".into(), json!(e.detail.clone().unwrap_or_default()));
        }
        Action::StartAgent => {
            p.insert("repo_path".into(), json!(e.worktree_path.as_deref()?));
            p.insert("prompt".into(), json!(e.detail.clone().unwrap_or_default()));
        }
        Action::DeleteWorktree => {
            p.insert("worktree_path".into(), json!(e.worktree_path.as_deref()?));
        }
    }
    describe_action(lang, action, &Value::Object(p))
}

/// A card's first line without its "First Mate:" lead, in either language.
fn strip_first_mate(line: &str) -> String {
    ["First Mate: ", "First Mate："].iter().find_map(|p| line.strip_prefix(p)).unwrap_or(line).to_string()
}

fn base_name(path: &str) -> String {
    Path::new(path).file_name().and_then(|n| n.to_str()).unwrap_or(path).to_string()
}

fn is_habit_auto(e: &Entry) -> bool {
    e.rule.as_deref().is_some_and(|r| r.starts_with("habit:")) && e.level.as_deref() == Some("auto")
}

fn is_approved_delete(e: &Entry) -> bool {
    e.action.as_deref() == Some("delete_worktree") && matches!(e.level.as_deref(), Some("approved" | "picked")) && e.worktree_path.is_some()
}

/// The brief's text: a title line, then one line per section that has
/// something — done, waiting on you, could go, notes. None when every
/// section is empty. Actions are described in the user's language from
/// their structured audit fields (`describe_entry`); an older line without
/// them is quoted as written.
pub fn compose(i: &Inputs) -> Option<String> {
    let l = i.lang;
    let actions: Vec<&Entry> = i.entries.iter().filter(|e| matches!(e.kind.as_str(), "action" | "research.started")).collect();
    let name = |e: &&Entry| e.worktree_path.as_deref().map(base_name).unwrap_or_else(|| e.text.clone());
    let by_habit: Vec<String> = actions.iter().filter(|e| is_habit_auto(e)).map(name).collect();
    let approved: Vec<String> = actions.iter().filter(|e| !is_habit_auto(e) && is_approved_delete(e)).map(name).collect();
    let others: Vec<String> = actions
        .iter()
        .filter(|e| !is_habit_auto(e) && !is_approved_delete(e))
        .map(|e| {
            let what = describe_entry(l, e).unwrap_or_else(|| e.text.clone());
            match e.level.as_deref() {
                Some("auto") => format!("{what}{}", l.pick(" (on my own)", "（自动）")),
                Some("approved" | "picked") => format!("{what}{}", l.pick(" (you approved)", "（你批准的）")),
                _ => what,
            }
        })
        .collect();
    let mut done = Vec::new();
    if !by_habit.is_empty() {
        done.push(match l {
            Lang::En => format!("deleted {} by habit — {}", plural_en(by_habit.len(), "worktree"), listed(&by_habit, l)),
            Lang::Zh => format!("按习惯删了 {} 个 worktree — {}", by_habit.len(), listed(&by_habit, l)),
        });
    }
    if !approved.is_empty() {
        done.push(match l {
            Lang::En => format!("deleted {} you approved — {}", plural_en(approved.len(), "worktree"), listed(&approved, l)),
            Lang::Zh => format!("删了你批准的 {} 个 worktree — {}", approved.len(), listed(&approved, l)),
        });
    }
    if !others.is_empty() {
        done.push(listed(&others, l));
    }
    let expired = i.entries.iter().filter(|e| e.kind == "expired").count();
    let mut notes: Vec<String> = i.notes.iter().map(|t| t.get(l).to_string()).collect();
    if expired > 0 {
        notes.push(match l {
            Lang::En => format!("{} withdrawn unanswered", plural_en(expired, "card")),
            Lang::Zh => format!("{expired} 张卡片没人回，已撤下"),
        });
    }
    if done.is_empty() && i.waiting.is_empty() && i.suggest.is_empty() && i.tasks.is_empty() && notes.is_empty() && i.research.is_empty() {
        return None;
    }
    let title = match (i.away, i.fallback) {
        (_, true) => l.pick("First Mate · daily brief (you have not been at the desk today)", "First Mate · 今日简报（你今天还没到电脑前）").to_string(),
        (Some(a), false) => format!("{} · {}", l.pick("First Mate · daily brief", "First Mate · 今日简报"), away(a, l)),
        (None, false) => l.pick("First Mate · daily brief", "First Mate · 今日简报").to_string(),
    };
    let sep = l.pick("; ", "；");
    let mut out = vec![title];
    if !done.is_empty() {
        out.push(format!("{}{}", l.pick("Done: ", "做了："), done.join(sep)));
    }
    if !i.waiting.is_empty() {
        let n = i.waiting.len();
        let mut line = match l {
            Lang::En => format!("Waiting on you ({}): {}", plural_en(n, "card"), listed(&i.waiting, l)),
            Lang::Zh => format!("等你处理（{n} 张卡片）：{}", listed(&i.waiting, l)),
        };
        if i.later > 0 {
            line += &match l {
                Lang::En => format!(" — {} of them come up as cards later", i.later),
                Lang::Zh => format!(" — 其中 {} 张稍后再弹出", i.later),
            };
        }
        out.push(line);
    }
    if !i.suggest.is_empty() {
        out.push(format!("{}{}", l.pick("Could go (no card): ", "可以清理（不发卡）："), listed(&i.suggest, l)));
    }
    if !i.tasks.is_empty() { out.push(format!("{}{}", l.pick("Could do: ", "可以做："), listed(&i.tasks, l))); }
    if !notes.is_empty() {
        out.push(format!("{}{}", l.pick("Notes: ", "备注："), notes.join(" · ")));
    }
    if !i.research.is_empty() { out.push(format!("{}{}", l.pick("Research: ", "调研："), i.research.join(" · "))); }
    Some(out.join("\n"))
}

/// Whether seahelm-gateway can reach Telegram now: `gateway.status` says
/// Telegram is on, has a token and is connected. No gateway: no.
pub fn telegram_ready() -> bool {
    crate::rpc::call_with_timeout(&gateway_socket(), "gateway.status", json!({}), std::time::Duration::from_secs(3)).is_ok_and(|v| ready_from_status(&v))
}

pub fn ready_from_status(v: &Value) -> bool {
    let t = &v["telegram"];
    let b = |k: &str| t.get(k).and_then(Value::as_bool).unwrap_or(false);
    b("enabled") && b("configured") && b("connected")
}

/// seahelm-gateway's admin socket, as the gateway resolves it
/// (`gateway/src/paths.rs`).
fn gateway_socket() -> std::path::PathBuf {
    if let Some(p) = std::env::var_os("SEAHELM_GATEWAY_SOCKET") {
        return p.into();
    }
    #[cfg(windows)]
    {
        let user = std::env::var("USERNAME").ok().filter(|u| !u.is_empty()).unwrap_or_else(|| "default".into());
        return format!(r"\\.\pipe\seahelm-gateway-{user}").into();
    }
    #[cfg(not(windows))]
    crate::rpc::config_dir().join("gateway.sock")
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
        strip_first_mate(self.message.lines().next().unwrap_or_default())
    }
}

/// How long a "Telegram is not reachable" answer is trusted.
const TELEGRAM_RECHECK: std::time::Duration = std::time::Duration::from_secs(5 * 60);

fn offset(now: f64) -> i64 {
    crate::usage::local_offset(now)
}

impl FirstMate {
    pub(super) fn save_budget(&self) {
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
        let options: Vec<super::lang::CardOption> = h.options.iter().enumerate().map(|(index,key)|
            {
                let mut option = super::lang::CardOption::new(key, self.config.language,index);
                if h.kind == CardKind::Proposal && index + 1 < h.options.len() {
                    option.key = format!("choice:{index}"); option.label = key.clone();
                }
                option
            }).collect();
        let labels = options.iter().map(|option| option.label.clone()).collect();
        self.card_options.insert(h.payload.clone(), options);
        self.core.raise_card(Raise {
            kind: Some(h.kind),
            worktree_path: self.dir.to_string_lossy().into(),
            project: pane::PROJECT.into(),
            message: h.message,
            options: labels,
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
        let ready = due.channel() != BriefChannel::Telegram || self.telegram_ok();
        let Some(channel) = due.settle(ready) else { return };
        let away = match due {
            Due::Arrival(_) => presence.profile.last_arrival.as_ref().and_then(|a| a.away),
            Due::Fallback => None,
        };
        self.send_brief(due, channel, away, now);
    }

    /// `telegram_ready`, asked at most every `TELEGRAM_RECHECK`: a fallback
    /// that cannot go waits, and would otherwise ask every tick.
    fn telegram_ok(&mut self) -> bool {
        if let Some((at, ok)) = self.telegram_checked {
            if at.elapsed() < TELEGRAM_RECHECK {
                return ok;
            }
        }
        let ok = (self.telegram_ready)();
        self.telegram_checked = Some((std::time::Instant::now(), ok));
        ok
    }

    /// Quiet hours: the user's own (`first_mate_quiet_hours`) or any known
    /// repo's (the brief is about all of them).
    pub(super) fn any_quiet_hours(&mut self, now: f64) -> bool {
        let local = super::clock::Local::at(now);
        if self.config.quiet_hours.is_some_and(|q| q.contains(&local)) {
            return true;
        }
        self.core.repos().iter().any(|r| self.config_for(r).ok().and_then(|c| c.settings.quiet_hours).is_some_and(|q| q.contains(&local)))
    }

    /// What the cards waiting on the user say: those up, then those held.
    fn waiting_lines(&self) -> Vec<String> {
        let mut out: Vec<String> = self
            .core
            .cards_with_payloads(|p| self.is_first_mates(p))
            .iter()
            .filter_map(|c| c.get("message").and_then(Value::as_str))
            .map(|m| strip_first_mate(m.lines().next().unwrap_or_default()))
            .collect();
        out.extend(self.held.iter().map(Held::headline));
        out
    }

    fn is_first_mates(&self, payload: &str) -> bool {
        self.task_cards.contains_key(payload) || self.approvals.contains_key(payload) || self.proposals.contains_key(payload) || self.is_habit_card(payload) || payload.starts_with("research.stop:")
    }

    pub(super) fn send_brief(&mut self, due: Due, channel: BriefChannel, away: Option<f64>, now: f64) {
        let day = budget::brief_day(now, offset(now));
        let since = if self.budget.last_brief_at > 0.0 { self.budget.last_brief_at } else { now - 86_400.0 };
        let since_iso = iso8601(since);
        let entries: Vec<Entry> = self.audit.recent(5000).into_iter().filter(|e| e.at > since_iso).collect();
        let tasks = self.task_brief(now);
        let inputs = Inputs {
            lang: self.config.language,
            away,
            fallback: due == Due::Fallback,
            entries,
            waiting: self.waiting_lines(),
            later: self.held.len().saturating_sub(budget::tuning::BRIEF_CARDS),
            suggest: self.budget.suggest.clone(),
            tasks,
            notes: self.budget.notes.clone(),
            research: self.research.pending(),
        };
        let Some(text) = compose(&inputs) else {
            self.budget.dealt_with(&day, None);
            self.save_budget();
            return;
        };
        self.research.delivered();
        self.research.save(&self.dir);
        self.core.first_mate_brief(&text);
        if channel == BriefChannel::Telegram {
            self.core.publish_event(json!({"type": "first_mate.brief", "text": text, "channel": channel.as_str()}));
        }
        let why = match due {
            Due::Arrival(_) => "on arrival",
            Due::Fallback => "not arrived by the usual start",
        };
        self.log(Entry::new(now, "brief", format!("daily brief to {} ({why}) — {}", channel.as_str(), text.replace('\n', " / "))));
        // What waited for the brief goes up with it, uncounted, a few at
        // a time: the rest are in its text and go up later by the usual rule.
        let n = self.held.len().min(budget::tuning::BRIEF_CARDS);
        for h in self.held.drain(..n).collect::<Vec<_>>() {
            self.raise_now(h, now);
        }
        self.budget.dealt_with(&day, Some(now));
        self.save_budget();
    }

    // MARK: expiry

    /// Withdraw First Mate's cards unanswered for `CARD_EXPIRY`.
    pub(super) fn expire_cards(&mut self, now: f64) {
        for payload in self.expiry.take_due_after(now, self.budget.tuned.expiry_days.clamp(1,7) as f64 * 86400.0) {
            if self.core.has_card_payload(&payload) {
                self.expire(&payload, now);
            }
        }
    }

    fn expire(&mut self, payload: &str, now: f64) {
        self.card_options.remove(payload);
        let proposed_habit = self.habit_proposals.remove(payload);
        let notes = self.budget.tuned.record(super::tuning::Evidence::Expired, None);
        for note in notes { self.log(Entry::new(now, "tuning", note.en.clone())); self.budget.note(note); }
        self.save_budget();
        self.core.expire_card_payload(payload);
        if self.task_cards.contains_key(payload) { self.expire_task(payload, now); return; }
        let today = super::clock::Local::at(now).day_key();
        let s = |p: &Value, k: &str| p.get(k).and_then(Value::as_str).unwrap_or_default().to_string();
        let mut habits: Vec<(String, String)> = Vec::new();
        let (kind, summary, worktree, repo) = if let Some(p) = proposed_habit {
            ("habit.propose", format!("habit {}", p.habit.id), String::new(), p.repo.unwrap_or_default())
        } else if let Some(a) = self.approvals.remove(payload) {
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
            // A question about a level, not an action: withdrawn, asked again
            // on fresh evidence; never `ignored`, never a demotion.
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
        let days = self.budget.tuned.expiry_days.clamp(1,7);
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
    fn actions_read_in_the_users_language_with_the_pane_by_name() {
        let mut e = action("Tell 3D827029-53B4-4174-A0FB-B9ABB1E7336E: PR #11403 failed", Some("fix-ci"), "auto", None);
        e.action = Some("message_pane".into());
        e.pane = Some("#7 · ru-guo-yao".into());
        e.detail = Some("PR #11403 的 pr-state-gate 失败了：关联 issue #11402 中有 3 项「交付验收」未勾选，请先补齐再推送".into());
        let i = Inputs { lang: Lang::Zh, entries: vec![e.clone()], ..Inputs::default() };
        let text = compose(&i).unwrap();
        let done = text.lines().nth(1).unwrap();
        assert!(done.starts_with("做了：告诉 #7 · ru-guo-yao：PR #11403 的 pr-state-gate 失败了"), "{done}");
        assert!(done.ends_with("…（自动）"), "{done}");
        assert!(!text.contains("3D827029"), "no raw pane id: {text}");
        let en = compose(&Inputs { lang: Lang::En, entries: vec![e], ..Inputs::default() }).unwrap();
        assert!(en.lines().nth(1).unwrap().starts_with("Done: tell #7 · ru-guo-yao: "), "{en}");
        // A line from before the structured fields is quoted as written.
        let old = action("Tell #3: hi", None, "auto", None);
        assert!(compose(&Inputs { lang: Lang::Zh, entries: vec![old], ..Inputs::default() }).unwrap().contains("Tell #3: hi（自动）"));
    }

    #[test]
    fn approvals_and_deletes_are_described_too() {
        use super::super::rules::Action;
        assert_eq!(describe_action(Lang::Zh, Action::StartAgent, &json!({"repo_path": "/w/seahelm", "prompt": "fix\nthe login"})).unwrap(), "在 seahelm 启动一个 agent：fix the login");
        assert_eq!(describe_action(Lang::Zh, Action::DeleteWorktree, &json!({"worktree_path": "/w/x/feat-a"})).unwrap(), "删除 worktree feat-a");
        assert_eq!(describe_action(Lang::En, Action::MessagePane, &json!({})), None);
        assert_eq!(strip_first_mate("First Mate：这 2 个 worktree 看起来已经做完了："), "这 2 个 worktree 看起来已经做完了：");
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

    fn sample(lang: Lang) -> Inputs {
        let mut approved = action("Deleted worktree c (approved, habit h)", None, "approved", Some("/w/wt/c"));
        approved.action = Some("delete_worktree".into());
        Inputs {
            lang,
            away: Some(13.0 * 3600.0),
            fallback: false,
            entries: vec![
                action("Deleted worktree a by habit h — …", Some("habit:delete-merged-clean"), "auto", Some("/w/wt/feat-a")),
                action("Deleted worktree b by habit h — …", Some("habit:delete-merged-clean"), "auto", Some("/w/wt/feat-b")),
                action("sent to #7: fix CI", None, "auto", None),
                approved,
                Entry::new(1.0, "expired", "withdrawn unanswered after 3 days: …"),
            ],
            waiting: vec!["these 2 worktrees look done:".into(), "First Mate asks: delete x".into()],
            research: vec![],
            later: 1,
            suggest: vec!["spike-x".into()],
            tasks: vec![],
            notes: vec![Text::new("Habit closed-idle down from ask to suggest: two of its cards went unanswered", "习惯 closed-idle 从 ask 降到 suggest：它的卡片连续两次没人回")],
        }
    }

    #[test]
    fn the_brief_reads_done_waiting_could_go_notes() {
        let text = compose(&sample(Lang::En)).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[0], "First Mate · daily brief · away 13 h");
        assert_eq!(lines[1], "Done: deleted 2 worktrees by habit — feat-a · feat-b; deleted 1 worktree you approved — c; sent to #7: fix CI (on my own)");
        assert_eq!(lines[2], "Waiting on you (2 cards): these 2 worktrees look done: · First Mate asks: delete x — 1 of them come up as cards later");
        assert_eq!(lines[3], "Could go (no card): spike-x");
        assert_eq!(lines[4], "Notes: Habit closed-idle down from ask to suggest: two of its cards went unanswered · 1 card withdrawn unanswered");
        assert_eq!(lines.len(), 5);
    }

    #[test]
    fn the_brief_in_chinese() {
        let text = compose(&sample(Lang::Zh)).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[0], "First Mate · 今日简报 · 离开了 13 小时");
        assert_eq!(lines[1], "做了：按习惯删了 2 个 worktree — feat-a · feat-b；删了你批准的 1 个 worktree — c；sent to #7: fix CI（自动）");
        assert_eq!(lines[2], "等你处理（2 张卡片）：these 2 worktrees look done: · First Mate asks: delete x — 其中 1 张稍后再弹出");
        assert_eq!(lines[3], "可以清理（不发卡）：spike-x");
        assert_eq!(lines[4], "备注：习惯 closed-idle 从 ask 降到 suggest：它的卡片连续两次没人回 · 1 张卡片没人回，已撤下");
        let fallback = compose(&Inputs { lang: Lang::Zh, fallback: true, suggest: vec!["a".into()], ..Inputs::default() }).unwrap();
        assert!(fallback.starts_with("First Mate · 今日简报（你今天还没到电脑前）\n"), "{fallback}");
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

        fm.send_brief(Due::Arrival(BriefChannel::Island), BriefChannel::Island, Some(10.0 * 3600.0), now);
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
        fm.send_brief(Due::Fallback, BriefChannel::Telegram, None, now);
        let crate::rpc::Reply::Value(Ok(v)) = core.clone().call("message.snapshot", serde_json::json!({"pane_id": super::super::policy::SESSION})) else { panic!() };
        assert!(v["messages"].as_array().unwrap().iter().all(|m| m["kind"] != "brief"));
        assert_eq!(fm.budget.brief_day, budget::brief_day(now, offset(now)));
        assert_eq!(fm.budget.last_brief_at, 0.0, "nothing went out");
        assert!(!audit_kinds(&fm).contains(&"brief".to_string()));
    }


    #[test]
    fn an_expired_level_offer_is_only_withdrawn() {
        let tmp = tempfile::tempdir().unwrap();
        let (core, mut fm) = first_mate(tmp.path());
        let now = seahelm_core_types::now();
        let today = super::super::clock::Local::at(now).day_key();
        fm.habits.ensure_seed(&today, now).unwrap();
        core.presence_signal(now, Some(Channel::Desktop));
        let offer = fm.offers.raise(GLOBAL, SEED_ID, HabitLevel::Auto, "n1");
        fm.put_card(CardKind::Approval, &offer.payload, "First Mate: promote?".into(), offer.options(), Class::Proactive, now);
        assert!(core.has_card_payload(&offer.payload));
        fm.expire_cards(now + budget::tuning::CARD_EXPIRY);
        assert!(!core.has_card_payload(&offer.payload) && !fm.offers.contains(&offer.payload));
        assert_eq!(seed_level(&fm, &today), (HabitLevel::Ask, 0, 0), "a question about a level: no ignored, no demotion");
        assert!(audit_kinds(&fm).contains(&"expired".to_string()));
        // A hand-written level's confirmation: withdrawn, not asked again while the file says the same.
        let c = fm.offers.raise_confirm(GLOBAL, SEED_ID, HabitLevel::Auto, "c1");
        fm.put_card(CardKind::Approval, &c.payload, "First Mate: confirm?".into(), c.options(), Class::Answering, now);
        fm.expire_cards(now + budget::tuning::CARD_EXPIRY);
        assert!(fm.confirm_expired(GLOBAL, SEED_ID, HabitLevel::Auto));
        assert_eq!(seed_level(&fm, &today), (HabitLevel::Ask, 0, 0));
    }

    #[test]
    fn the_brief_puts_up_three_held_cards_and_lists_the_rest() {
        let tmp = tempfile::tempdir().unwrap();
        let (core, mut fm) = first_mate(tmp.path());
        let now = seahelm_core_types::now();
        let payloads: Vec<String> = (0..5)
            .map(|i| {
                let p = format!("proposal-{i}");
                fm.put_card(CardKind::Proposal, &p, format!("First Mate suggests: {i}"), vec!["Go".into(), "Not now".into()], Class::Proactive, now);
                p
            })
            .collect();
        assert_eq!(fm.held.len(), 5, "nobody there: all held");
        fm.send_brief(Due::Fallback, BriefChannel::Island, None, now);
        let up = payloads.iter().filter(|p| core.has_card_payload(p)).count();
        assert_eq!(up, budget::tuning::BRIEF_CARDS);
        assert_eq!(fm.held.len(), 2, "the rest stay held for the usual rule");
        let text = fm.audit.recent(50).into_iter().find(|e| e.kind == "brief").unwrap().text;
        assert!(text.contains("Waiting on you (5 cards)") && text.contains("2 of them come up as cards later"), "{text}");
        // Later, with the user there and room under the cap, they go up.
        core.presence_signal(now + 60.0, Some(Channel::Desktop));
        fm.release_held(now + 60.0);
        assert!(fm.held.is_empty());
        assert!(payloads.iter().all(|p| core.has_card_payload(p)));
    }

    #[test]
    fn a_ci_failures_approval_goes_up_at_once_and_a_cleanup_waits() {
        let tmp = tempfile::tempdir().unwrap();
        let (core, mut fm) = first_mate(tmp.path());
        let now = seahelm_core_types::now();
        let config = super::super::rules::Config::built_in();
        let rule = |trigger: super::super::rules::Trigger| config.rules.iter().find(|r| r.trigger == trigger).unwrap().clone();
        let params = serde_json::json!({"worktree_path": "/nonexistent/wt/x"});
        // Nobody there. A CI failure's ask: up now, uncounted.
        fm.active_rules = vec![(rule(super::super::rules::Trigger::CiFailed), config.clone())];
        let super::super::Gate::Queued(ci) = fm.gate(super::super::rules::Action::DeleteWorktree, "worktree.delete", &params, now) else { panic!() };
        assert!(core.has_card_payload(&ci));
        assert_eq!(fm.budget.cards_today, 0);
        // cleanup-merged's: waits for the brief.
        fm.active_rules = vec![(rule(super::super::rules::Trigger::PrMerged), config.clone())];
        let super::super::Gate::Queued(cleanup) = fm.gate(super::super::rules::Action::DeleteWorktree, "worktree.delete", &params, now) else { panic!() };
        assert!(!core.has_card_payload(&cleanup));
        assert_eq!(fm.held.len(), 1);
    }

    #[test]
    fn telegram_status_is_read_from_the_gateway() {
        let ok = serde_json::json!({"telegram": {"enabled": true, "configured": true, "connected": true}});
        assert!(ready_from_status(&ok));
        for off in ["enabled", "configured", "connected"] {
            let mut v = ok.clone();
            v["telegram"][off] = serde_json::json!(false);
            assert!(!ready_from_status(&v), "{off}");
        }
        assert!(!ready_from_status(&serde_json::json!({})));
    }

}
