//! First Mate's side of the habits (`habits`, `sweep`): the daily sweep,
//! the evidence it counts first, the promotion cards, and the answers to
//! habit cards. Runs on First Mate's thread; measuring and deleting go to a
//! thread of their own and come back as `Msg::Swept` / `Msg::HabitDeleted`,
//! so no gate call waits on git.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use seahelm_core_registry::cards::{CardKind, Raise};

use super::clock::Local;
use super::engine::Entry;
use super::habits::{self, Book, Change, Decision, OfferAnswer, Precedence, Store, GLOBAL};
use super::observations::{self, norm, By};
use super::rules::{Action, Level};
use super::sweep::{self, Batch, BatchAnswer, Candidate, Deleter, Routed};
use super::{pane, FirstMate, Msg};
use crate::core::Core;

/// How often the sweep looks whether a repo is due (it lists repos with git).
const SWEEP_CHECK_EVERY: Duration = Duration::from_secs(10 * 60);
/// How often the habit files are read for levels raised by hand.
const HAND_CHECK_EVERY: Duration = Duration::from_secs(60);
/// A sweep running longer than this is taken for dead.
const SWEEP_STUCK: Duration = Duration::from_secs(60 * 60);

/// The core's own `worktree.delete`, for a habit: measured again first,
/// and only if the same habit still decides the worktree (and, for an
/// automatic deletion, at `auto`, with nothing to lose).
pub struct CoreDeleter {
    pub core: Arc<Core>,
    pub books: HashMap<String, Book>,
    pub global: Book,
    pub prec: HashMap<String, Precedence>,
    pub default_prec: Precedence,
    /// The card the user answered, for a deletion they approved.
    pub card: Option<String>,
}

impl CoreDeleter {
    fn recheck(&self, r: &Routed, automatic: bool) -> Result<(), String> {
        let facts = self.core.measure_worktree(&r.candidate.path, None);
        let mut list: Vec<&Book> = Vec::new();
        if let Some(b) = self.books.get(&r.candidate.repo) {
            list.push(b);
        }
        list.push(&self.global);
        let prec = self.prec.get(&norm(&r.candidate.repo)).copied().unwrap_or(self.default_prec);
        let d = habits::decide(&facts, &list, &prec);
        let same = d.as_ref().is_some_and(|d| d.key == r.decision.key && d.id == r.decision.id);
        if !same {
            return Err(format!("no longer matches {} ({})", r.decision.id, facts.summary()));
        }
        if automatic && (d.map(|d| d.level) != Some(habits::HabitLevel::Auto) || !habits::nothing_to_lose(&facts)) {
            return Err(format!("not safe to delete on its own any more ({})", facts.summary()));
        }
        Ok(())
    }
}

impl Deleter for CoreDeleter {
    fn delete(&self, r: &Routed, how: &str) -> Result<(), String> {
        self.recheck(r, how.starts_with("habit:"))?;
        let params = json!({"worktree_path": r.candidate.path});
        let result = self.core.act("worktree.delete", &params).map_err(|e| e.message)?;
        self.core.note_performed("worktree.delete", &params, &result, By::FirstMate, Some(how), self.card.as_deref(), None);
        Ok(())
    }
}

impl FirstMate {
    fn today(now: f64) -> String {
        Local::at(now).day_key()
    }

    /// A repo's precedence over habits; None when its rules do not parse
    /// (First Mate's automation is stopped there).
    pub(super) fn precedence(&mut self, repo: &str) -> Option<Precedence> {
        let config = self.config_for(repo).ok()?;
        let own = Path::new(repo).join(super::rules::RELATIVE_PATH).exists();
        Some(Precedence { repo_cap: habits::repo_cap(&config, own), user_default: self.user_delete_default() })
    }

    fn user_delete_default(&self) -> Level {
        self.config.defaults.get(&Action::DeleteWorktree).copied().unwrap_or(Level::Ask)
    }

    fn default_prec(&self) -> Precedence {
        Precedence { repo_cap: None, user_default: self.user_delete_default() }
    }

    /// The repo books by repo path, and the global one.
    fn books_for(&self, repos: &[String], today: &str) -> (HashMap<String, Book>, Book) {
        let books = repos.iter().map(|r| (r.clone(), self.habits.load(&habits::repo_key(r), today))).collect();
        (books, self.habits.load(GLOBAL, today))
    }

    fn save_book(&mut self, b: &Book, now: f64) {
        if let Err(e) = self.habits.save(b, now) {
            eprintln!("seahelm-core: habits {}: {e}", b.key);
        }
    }

    /// One line in First Mate's conversation, and the audit.
    fn report(&mut self, kind: &str, text: &str, now: f64) {
        self.core.first_mate_line(text);
        self.log(Entry::new(now, kind, text));
    }

    fn report_change(&mut self, c: &Change, now: f64) {
        self.report("habit", &c.line(), now);
    }

    // MARK: the sweep

    /// Sweep if a repo is due: once a local day, or now if First Mate was
    /// just turned on. Never while paused or in a repo's quiet hours.
    pub(super) fn maybe_sweep(&mut self, now: f64) {
        // A sweep thread that never reported (it died) does not block the next.
        if self.sweep_running.is_some_and(|t| t.elapsed() < SWEEP_STUCK) || self.config.paused {
            return;
        }
        if !self.sweep_forced && self.sweep_checked.is_some_and(|t| t.elapsed() < SWEEP_CHECK_EVERY) {
            return;
        }
        self.sweep_checked = Some(Instant::now());
        let fm_dir = self.dir.to_string_lossy().into_owned();
        let live: HashSet<String> = self.core.live_worktrees().into_iter().filter(|w| *w != fm_dir).collect();
        if live.is_empty() {
            return;
        }
        let local = Local::at(now);
        let day = local.day_key();
        let forced = self.sweep_forced;
        let mut due: HashSet<String> = HashSet::new();
        let mut prec: HashMap<String, Precedence> = HashMap::new();
        let repos = self.all_repos();
        for repo in repos.clone() {
            let Ok(config) = self.config_for(&repo) else { continue };
            if config.settings.quiet_hours.is_some_and(|q| q.contains(&local)) {
                continue;
            }
            if !forced && !self.sweep_state.due(&repo, &day) {
                continue;
            }
            if let Some(p) = self.precedence(&repo) {
                self.habits.remember_repo(&habits::repo_key(&repo), &repo);
                prec.insert(norm(&repo), p);
                due.insert(norm(&repo));
                self.sweep_state.swept.insert(repo.clone(), day.clone());
            }
        }
        if due.is_empty() {
            return;
        }
        self.sweep_forced = false;
        self.sweep_state.last_at = now;
        self.sweep_state.save(&sweep::State::path(&self.habits.dir));
        self.learn(now);

        let today = Self::today(now);
        let (books, global) = self.books_for(&repos, &today);
        let skip = self.on_cards();
        let deleter = CoreDeleter { core: self.core.clone(), books: books.clone(), global: global.clone(), prec: prec.clone(), default_prec: self.default_prec(), card: None };
        let core = self.core.clone();
        let tx = self.tx.clone();
        self.sweep_running = Some(Instant::now());
        std::thread::spawn(move || {
            let integration = crate::discovery::Filter::live(&crate::rpc::config_dir()).integration;
            let targets = sweep::targets(&live, observations::worktree_info, &integration, &skip);
            let candidates: Vec<Candidate> = targets
                .into_iter()
                .filter(|t| due.contains(&norm(&t.repo)))
                .map(|t| Candidate { facts: core.measure_worktree(&t.path, None), path: t.path, repo: t.repo, branch: t.branch })
                .collect();
            // Books are keyed by the repo path `core.repos()` gave; a target's
            // repo is the same main checkout, compared canonically.
            let books_by_norm: HashMap<String, Book> = books.into_iter().map(|(r, b)| (norm(&r), b)).collect();
            let candidates = candidates.into_iter().map(|mut c| {
                c.repo = norm(&c.repo);
                c
            });
            let deleter = CoreDeleter { books: books_by_norm.clone(), ..deleter };
            let plan = sweep::plan(candidates.collect(), &books_by_norm, &global, |r| prec.get(r).copied().unwrap_or(deleter.default_prec));
            let report = sweep::run(plan, &deleter);
            let _ = tx.send(Msg::Swept { report });
        });
    }

    /// Every repo the core knows: those of the worktrees clients list, and
    /// the repo set the core keeps for discovering worktrees itself
    /// (`discovery`, phase 3a), so a repo only the core found is swept too.
    fn all_repos(&self) -> Vec<String> {
        let mut out = self.core.repos();
        let set = crate::discovery::RepoSet::open(crate::rpc::config_dir().join(crate::discovery::FILE_NAME));
        for r in set.repos() {
            if Path::new(&r).is_dir() && !out.iter().any(|o| norm(o) == norm(&r)) {
                out.push(r);
            }
        }
        out
    }

    /// Hand-raised levels in the habit files (D12): one confirmation card
    /// per habit, until the user answers. Meanwhile the level the core
    /// granted applies.
    pub(super) fn check_hand_edits(&mut self, now: f64) {
        if self.config.paused || self.hand_checked.is_some_and(|t| t.elapsed() < HAND_CHECK_EVERY) {
            return;
        }
        self.hand_checked = Some(Instant::now());
        let today = Self::today(now);
        for b in self.habits.all(&today) {
            for (id, to, from) in b.pending_confirmations() {
                if self.offers.pending(&b.key, &id) {
                    continue;
                }
                let Some(h) = b.get(&id) else { continue };
                let nonce = self.mint("c");
                let offer = self.offers.raise_confirm(&b.key, &id, to, &nonce);
                let message = habits::confirm_message(h, to, from, &self.habits.path(&b.key));
                self.raise(&offer.payload, message, offer.options());
                self.log(Entry::new(now, "approval", format!("habit {id}: {} written by hand, held at {} until confirmed", to.as_str(), from.as_str())));
            }
        }
    }

    /// Worktrees already on one of First Mate's cards.
    fn on_cards(&self) -> HashSet<String> {
        let mut out: HashSet<String> = self.approvals.values().filter_map(|a| a.params.get("worktree_path").and_then(Value::as_str)).map(norm).collect();
        for b in self.batches.values() {
            out.extend(b.items.iter().map(|r| norm(&r.candidate.path)));
        }
        out.insert(norm(&self.dir.to_string_lossy()));
        out
    }

    pub(super) fn swept(&mut self, report: sweep::Report, now: f64) {
        self.sweep_running = None;
        for r in &report.deleted {
            let mut e = Entry::new(now, "action", format!("Deleted worktree {} by habit {} — {}", r.candidate.name(), r.decision.id, r.candidate.facts.summary()));
            e.action = Some(Action::DeleteWorktree.as_str().into());
            e.level = Some("auto".into());
            e.rule = Some(format!("habit:{}", r.decision.id));
            e.worktree_path = Some(r.candidate.path.clone());
            self.log(e);
            self.sweep_state.deleted.push(sweep::Deleted {
                key: r.decision.key.clone(),
                id: r.decision.id.clone(),
                repo: r.candidate.repo.clone(),
                branch: r.candidate.branch.clone(),
                worktree: r.candidate.path.clone(),
                at: now,
            });
        }
        if let Some(line) = sweep::line_deleted(&report.deleted) {
            self.core.first_mate_line(&line);
        }
        for (r, why) in &report.failed {
            let mut e = Entry::new(now, "skipped", format!("{} not deleted by habit {} — {why}", r.candidate.name(), r.decision.id));
            e.worktree_path = Some(r.candidate.path.clone());
            self.log(e);
        }
        // Turned off while the sweep measured: what was deleted is reported,
        // nothing new is put to the user.
        if !self.running {
            self.sweep_state.save(&sweep::State::path(&self.habits.dir));
            return;
        }
        if let Some(line) = sweep::line_suggest(&report.suggest) {
            self.report("event", &line, now);
        }
        if !report.ask.is_empty() {
            // One batched card per sweep: an older one still open is replaced.
            for old in std::mem::take(&mut self.batches).into_keys() {
                self.core.drop_card_payload(&old);
            }
            for old in std::mem::take(&mut self.items).into_keys() {
                self.core.drop_card_payload(&old);
            }
            let nonce = self.mint("sweep");
            let batch = Batch::new(&nonce, report.ask);
            let (message, options) = batch.card();
            self.raise(&batch.payload, message.clone(), options);
            self.log(Entry::new(now, "approval", message.lines().next().unwrap_or_default().to_string()));
            self.batches.insert(batch.payload.clone(), batch);
        }
        self.sweep_state.save(&sweep::State::path(&self.habits.dir));
    }

    fn raise(&self, payload: &str, message: String, options: Vec<String>) {
        self.core.raise_card(Raise {
            kind: Some(CardKind::Approval),
            worktree_path: self.dir.to_string_lossy().into(),
            project: pane::PROJECT.into(),
            message,
            options,
            payload: Some(payload.into()),
            ..Raise::default()
        });
    }

    // MARK: evidence and promotion

    /// Count what the observation log shows (manual removals, undone
    /// automatic deletions), apply the automatic moves, and offer the
    /// promotions that are due, each on a card of its own.
    pub(super) fn learn(&mut self, now: f64) {
        let today = Self::today(now);
        let records = observations::read_records(&self.dir.join(observations::FILE_NAME));
        for d in self.sweep_state.undone(&records, now) {
            let mut b = self.habits.load(&d.key, &today);
            if let Some(c) = b.undone(&d.id, &d.branch) {
                self.save_book(&b, now);
                self.report_change(&c, now);
            }
        }
        let fm_dir = self.dir.to_string_lossy().into_owned();
        for mut b in self.habits.all(&today) {
            let key = b.key.clone();
            let changes = b.count(&records, |r| r.worktree != fm_dir && (key == GLOBAL || habits::repo_key(&r.repo) == key));
            let before = self.habits.load(&key, &today);
            if b != before || !self.habits.path(&key).exists() {
                self.save_book(&b, now);
            }
            for c in &changes {
                self.report_change(c, now);
            }
            for (id, level) in b.offers_due(&records) {
                if self.offers.pending(&key, &id) {
                    continue;
                }
                let Some(h) = b.get(&id) else { continue };
                let nonce = self.mint("n");
                let offer = self.offers.raise(&key, &id, level, &nonce);
                let message = habits::offer_message(h, level, b.level(h));
                self.raise(&offer.payload, message, offer.options());
                self.log(Entry::new(now, "approval", format!("offered: habit {id} to {}", level.as_str())));
            }
        }
        self.sweep_state.save(&sweep::State::path(&self.habits.dir));
    }

    // MARK: answers

    /// A habit card was answered. Returns false when the payload is not one.
    pub(super) fn answered_habit(&mut self, payload: &str, option: Option<&str>, via: Option<String>, now: f64) -> bool {
        if payload.starts_with(habits::PROMOTE_PREFIX) || payload.starts_with(habits::CONFIRM_PREFIX) {
            self.answer_offer(payload, option, via, now);
        } else if payload.starts_with(sweep::SWEEP_PREFIX) {
            self.answer_batch(payload, option, via, now);
        } else if payload.starts_with(sweep::ITEM_PREFIX) {
            self.answer_item(payload, option, via, now);
        } else {
            return false;
        }
        true
    }

    #[allow(clippy::too_many_arguments)]
    fn observe_habit_answer(&self, kind: &'static str, card: &str, option: Option<&str>, via: Option<String>, summary: String, habit: String, worktree: String) {
        self.core.observe(observations::Msg::CardAnswered {
            card_kind: kind,
            card: card.into(),
            option: option.map(str::to_string),
            via,
            summary,
            action: Some(Action::DeleteWorktree.as_str().into()),
            worktree,
            repo: String::new(),
            habit: Some(habit),
        });
    }

    /// A promotion or a hand-edit confirmation answered.
    fn answer_offer(&mut self, payload: &str, option: Option<&str>, via: Option<String>, now: f64) {
        let today = Self::today(now);
        let Some(answer) = self.offers.answer(payload, option) else { return };
        let (key, id, confirm) = match &answer {
            OfferAnswer::Accepted(g) => (g.key.clone(), g.id.clone(), g.confirm),
            OfferAnswer::Declined { key, id, confirm } => (key.clone(), id.clone(), *confirm),
        };
        let (kind, what) = if confirm { ("habit.confirm", "confirm") } else { ("habit.promote", "promote") };
        self.observe_habit_answer(kind, payload, option, via, format!("{what} habit {id}"), format!("{key}/{id}"), String::new());
        let mut b = self.habits.load(&key, &today);
        match answer {
            OfferAnswer::Accepted(g) => {
                let applied = if confirm { b.confirm(g, &today) } else { b.promote(g, &today) };
                match applied {
                    Ok(c) => {
                        self.save_book(&b, now);
                        self.report_change(&c, now);
                    }
                    Err(e) => self.log(Entry::new(now, "denied", format!("habit {id} not raised — {e}"))),
                }
            }
            OfferAnswer::Declined { confirm: true, .. } => {
                if let Some((written, granted)) = b.revert(&id) {
                    self.save_book(&b, now);
                    self.report("habit", &format!("Habit {id} put back to {} in the file (it said {})", granted.as_str(), written.as_str()), now);
                }
            }
            OfferAnswer::Declined { .. } => {
                b.declined(&id);
                self.save_book(&b, now);
                self.log(Entry::new(now, "denied", format!("not yet: habit {id} stays where it is")));
            }
        }
    }

    fn answer_batch(&mut self, payload: &str, option: Option<&str>, via: Option<String>, now: f64) {
        let Some(batch) = self.batches.get(payload).cloned() else { return };
        let summary = batch.card().0.lines().next().unwrap_or_default().to_string();
        let habit = batch.items.first().map(|r| format!("{}/{}", r.decision.key, r.decision.id)).unwrap_or_default();
        self.observe_habit_answer("habit.sweep", payload, option, via, summary.clone(), habit, String::new());
        match sweep::answer_batch(&batch, option) {
            BatchAnswer::Delete(idxs) => {
                self.batches.remove(payload);
                let items: Vec<Routed> = idxs.iter().map(|i| batch.items[*i].clone()).collect();
                self.approve(&items, payload, now);
            }
            BatchAnswer::Keep(i) => {
                self.batches.remove(payload);
                self.reject(&batch.items[i], true, now);
            }
            BatchAnswer::Pick => {
                for i in batch.open.clone() {
                    let p = batch.item_payload(i);
                    let (message, options) = batch.item_card(i);
                    self.raise(&p, message, options);
                    self.items.insert(p, (payload.to_string(), i));
                }
            }
            BatchAnswer::Nothing => {
                self.batches.remove(payload);
                self.log(Entry::new(now, "denied", format!("not now: {summary}")));
            }
        }
    }

    fn answer_item(&mut self, payload: &str, option: Option<&str>, via: Option<String>, now: f64) {
        let Some((batch_payload, i)) = self.items.remove(payload) else { return };
        let Some(batch) = self.batches.get_mut(&batch_payload) else { return };
        batch.open.retain(|x| *x != i);
        let Some(r) = batch.items.get(i).cloned() else { return };
        let first_no = batch.demoted.insert((r.decision.key.clone(), r.decision.id.clone()));
        let done = batch.open.is_empty();
        if done {
            self.batches.remove(&batch_payload);
        }
        self.observe_habit_answer("habit.item", payload, option, via, format!("delete worktree {}", r.candidate.name()), format!("{}/{}", r.decision.key, r.decision.id), r.candidate.path.clone());
        match option {
            Some(sweep::DELETE) => {
                // Not a no after all: let a later Keep in this batch demote.
                if first_no {
                    if let Some(b) = self.batches.get_mut(&batch_payload) {
                        b.demoted.remove(&(r.decision.key.clone(), r.decision.id.clone()));
                    }
                }
                self.approve(std::slice::from_ref(&r), payload, now);
            }
            Some(sweep::KEEP) => self.reject(&r, first_no, now),
            _ => {}
        }
    }

    /// The user approved deleting these: one approval per habit, then the
    /// deletions, each measured and matched again first.
    fn approve(&mut self, items: &[Routed], card: &str, now: f64) {
        let today = Self::today(now);
        let mut by_habit: HashMap<(String, String), Vec<String>> = HashMap::new();
        for r in items {
            by_habit.entry((r.decision.key.clone(), r.decision.id.clone())).or_default().push(r.candidate.branch.clone());
        }
        for ((key, id), branches) in by_habit {
            let mut b = self.habits.load(&key, &today);
            b.approved(&id, &branches);
            self.save_book(&b, now);
        }
        let repos: Vec<String> = items.iter().map(|r| r.candidate.repo.clone()).collect::<HashSet<_>>().into_iter().collect();
        let mut prec = HashMap::new();
        for repo in &repos {
            if let Some(p) = self.precedence(repo) {
                prec.insert(norm(repo), p);
            }
        }
        let (books, global) = self.books_for(&repos, &today);
        let books: HashMap<String, Book> = books.into_iter().map(|(r, b)| (norm(&r), b)).collect();
        let deleter = CoreDeleter { core: self.core.clone(), books, global, prec, default_prec: self.default_prec(), card: Some(card.into()) };
        let tx = self.tx.clone();
        let items = items.to_vec();
        std::thread::spawn(move || {
            for r in items {
                let result = deleter.delete(&r, "approved");
                let _ = tx.send(Msg::HabitDeleted { routed: r, result });
            }
        });
    }

    fn reject(&mut self, r: &Routed, demote: bool, now: f64) {
        let today = Self::today(now);
        let mut b = self.habits.load(&r.decision.key, &today);
        let change = if demote {
            b.rejected(&r.decision.id)
        } else {
            b.note_rejected(&r.decision.id);
            None
        };
        self.save_book(&b, now);
        self.log(Entry::new(now, "denied", format!("kept: {} (habit {})", r.candidate.name(), r.decision.id)));
        if let Some(c) = change {
            self.report_change(&c, now);
        }
    }

    pub(super) fn habit_deleted(&mut self, r: Routed, result: Result<(), String>, now: f64) {
        match result {
            Ok(()) => {
                let mut e = Entry::new(now, "action", format!("Deleted worktree {} (approved, habit {})", r.candidate.name(), r.decision.id));
                e.action = Some(Action::DeleteWorktree.as_str().into());
                e.level = Some("approved".into());
                e.worktree_path = Some(r.candidate.path.clone());
                self.log(e);
                self.core.first_mate_line(&format!("Deleted {}. Branch kept.", r.candidate.name()));
            }
            Err(why) => self.report("skipped", &format!("Did not delete {}: {why}", r.candidate.name()), now),
        }
    }

    /// A First Mate delete approval (a rule's, not a habit card) answered:
    /// evidence for the habit its measured facts match, if any.
    pub(super) fn count_delete_approval(&mut self, params: &Value, approved: bool, now: f64) -> Option<String> {
        let facts: super::facts::Facts = serde_json::from_value(params.get("_facts_json")?.clone()).ok()?;
        let worktree = params.get("worktree_path").and_then(Value::as_str)?;
        let (repo, _) = observations::worktree_info(worktree)?;
        let today = Self::today(now);
        let prec = self.precedence(&repo).unwrap_or(self.default_prec());
        let (books, global) = self.books_for(std::slice::from_ref(&repo), &today);
        let mut list: Vec<&Book> = books.values().collect();
        list.push(&global);
        let Decision { key, id, .. } = habits::decide(&facts, &list, &prec)?;
        let mut b = self.habits.load(&key, &today);
        if approved {
            let branch = observations::worktree_info(worktree).map(|(_, b)| b).unwrap_or_default();
            b.approved(&id, &[branch]);
            self.save_book(&b, now);
        } else if let Some(c) = b.rejected(&id) {
            self.save_book(&b, now);
            self.report_change(&c, now);
        } else {
            self.save_book(&b, now);
        }
        Some(format!("{key}/{id}"))
    }

    /// Every habit card First Mate has up.
    pub(super) fn habit_payloads(&self) -> Vec<String> {
        let mut out = self.offers.payloads();
        out.extend(self.batches.keys().cloned());
        out.extend(self.items.keys().cloned());
        out
    }

    pub(super) fn is_habit_card(&self, payload: &str) -> bool {
        self.offers.contains(payload) || self.batches.contains_key(payload) || self.items.contains_key(payload)
    }

    pub(super) fn drop_habit_cards(&mut self) {
        for p in self.habit_payloads() {
            self.core.drop_card_payload(&p);
        }
        self.offers.clear();
        self.batches.clear();
        self.items.clear();
        self.sweep_checked = None;
        self.hand_checked = None;
    }
}

/// `habits.list {repo?}`, read-only: from the files, with each repo's
/// precedence read from its rules and the user's config.
pub fn list(params: &Value) -> Value {
    let store = Store::new(Store::default_dir());
    let now = seahelm_core_types::now();
    let today = Local::at(now).day_key();
    let user = super::UserConfig::load();
    let default = user.defaults.get(&Action::DeleteWorktree).copied().unwrap_or(Level::Ask);
    let repo = params.get("repo").and_then(Value::as_str).filter(|r| !r.is_empty()).map(|r| {
        // A worktree names its repo.
        observations::worktree_info(r).map(|(repo, _)| repo).unwrap_or_else(|| r.to_string())
    });
    habits::list_json(&store, repo.as_deref(), &today, |repo| {
        let own = Path::new(repo).join(super::rules::RELATIVE_PATH).exists();
        // Rules that do not parse stop First Mate in the repo: nothing acts.
        let cap = match super::rules::Config::load(Path::new(repo)) {
            Ok(c) => habits::repo_cap(&c, own),
            Err(_) => Some(Level::Deny),
        };
        Precedence { repo_cap: cap, user_default: default }
    })
}

/// The habit RPCs the core answers. Read-only: nothing here, or anywhere
/// else outside a promotion card's answer, raises a level.
pub fn rpc(method: &str, params: &Value) -> Option<Value> {
    match method {
        "habits.list" => Some(list(params)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::first_mate::policy::{self, Class};

    #[test]
    fn nothing_but_a_card_raises_a_level() {
        // The core answers one habit RPC, and it only reads.
        for m in ["habits.promote", "habits.set", "habits.set_level", "habits.update", "habits.write", "habit.promote", "habits.grant", "habits.undo"] {
            assert!(rpc(m, &json!({"id": habits::SEED_ID, "level": "auto"})).is_none(), "{m}");
            // First Mate may not call any of them, nor answer or raise a card.
            assert_eq!(policy::classify(m), Class::Forbidden, "{m}");
        }
        assert_eq!(policy::classify("habits.list"), Class::Open);
        for m in ["cards.answer", "cards.raise", "autopilot.answer", "cards.dismiss"] {
            assert_eq!(policy::classify(m), Class::Forbidden, "{m}");
        }
    }
}
