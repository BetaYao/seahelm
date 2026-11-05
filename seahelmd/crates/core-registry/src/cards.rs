//! Cards: everything that waits on the user, in one queue every client
//! renders (docs/first-mate-core.md).
//!
//! Ported from the app's `PendingOrdersQueue`, `SuggestionSeenSet`, the card
//! half of `FirstMate.evaluate` / `FirstMateCoordinator`, and the answer
//! paths of `MainWindowController.handleSuggestionTapped`. Pure: the queue
//! decides, and an answer comes back as the keys to press, which the caller
//! sends to the pane's seahelmd session.
//!
//! A card's key is the app's (`worktree#kind#pane[#payload]`), so a newer
//! suggestion from a pane replaces its older one in place. Its id is minted
//! here and stays while the key is on offer; a card that leaves and comes
//! back gets a new one, so a tap on a card already answered names nothing.

use std::collections::HashMap;

use serde_json::{json, Value};

use seahelm_core_types::{AgentStatus, AgentType, EventKind, EventSource, QuestionFlags, QuestionSpec, Timestamp};

use crate::registry::Outcome;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CardKind {
    /// AskUserQuestion, from a hook: answered in the agent's dialog.
    Question,
    /// A numbered choice the scan found on screen (a permission prompt).
    Choice,
    /// The agent's suggested next orders (`::seahelm-suggest::`).
    Suggestion,
    /// Raised by a client (an integration round that needs looking at).
    Report,
    /// First Mate wants to do something its policy says to ask about.
    Approval,
    /// First Mate's recommendation with options.
    Proposal,
}

impl CardKind {
    pub fn as_str(self) -> &'static str {
        match self {
            CardKind::Question => "question",
            CardKind::Choice => "choice",
            CardKind::Suggestion => "suggestion",
            CardKind::Report => "report",
            CardKind::Approval => "approval",
            CardKind::Proposal => "proposal",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "question" => CardKind::Question,
            "choice" => CardKind::Choice,
            "suggestion" => CardKind::Suggestion,
            "report" => CardKind::Report,
            "approval" => CardKind::Approval,
            "proposal" => CardKind::Proposal,
            _ => return None,
        })
    }

    /// Cards that answer a question on the pane's screen.
    fn is_question(self) -> bool {
        matches!(self, CardKind::Question | CardKind::Choice)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Card {
    pub id: String,
    pub kind: CardKind,
    /// The pane's key (seahelmd session); empty for worktree or app cards.
    pub pane: String,
    pub alias: Option<String>,
    pub worktree_path: String,
    pub branch: String,
    pub project: String,
    pub message: String,
    pub options: Vec<String>,
    /// Remaining questions of a multi-question AskUserQuestion.
    pub followups: Vec<QuestionSpec>,
    pub flags: QuestionFlags,
    /// Whatever the raiser needs back (a report's repo, an approval's id).
    pub payload: Option<String>,
    pub created_at: Timestamp,
    /// When the card last became worth showing again: new, or what it asks
    /// changed. A renderer pops for a card whose `fresh_at` is past the one
    /// it last showed (the app's `SuggestionSeenSet`).
    pub fresh_at: Timestamp,
}

/// The extra button on a multi-select card that leaves the question.
pub const DONE_LABEL: &str = "✔ Done";

impl Card {
    fn key(&self) -> String {
        let mut k = format!("{}#{}", self.worktree_path, self.kind.as_str());
        if !self.pane.is_empty() {
            k.push('#');
            k.push_str(&self.pane);
        }
        if let Some(p) = &self.payload {
            k.push('#');
            k.push_str(p);
        }
        k
    }

    /// What the card offers to tap: its options, ticked on a multi-select
    /// question, which then also offers Done.
    pub fn labels(&self) -> Vec<String> {
        if !self.flags.multi_select {
            return self.options.clone();
        }
        let mut out: Vec<String> = self
            .options
            .iter()
            .enumerate()
            .map(|(i, o)| format!("{}{o}", if self.flags.checked.contains(&i) { "☑ " } else { "☐ " }))
            .collect();
        out.push(DONE_LABEL.into());
        out
    }

    pub fn to_json(&self) -> Value {
        let mut v = json!({
            "id": self.id,
            "kind": self.kind.as_str(),
            "pane_session_key": self.pane,
            "pane_id": self.alias.clone().unwrap_or_else(|| self.pane.clone()),
            "worktree_path": self.worktree_path,
            "branch": self.branch,
            "project": self.project,
            "message": self.message,
            "options": self.options,
            "labels": self.labels(),
            "created_at": self.created_at,
            "fresh_at": self.fresh_at,
        });
        // What Claude's dialog shows beside the question: its tab title, and a
        // line under each option. Only on cards that have them.
        if !self.flags.header.is_empty() {
            v["header"] = json!(self.flags.header);
        }
        if !self.flags.details.is_empty() {
            v["details"] = json!(self.flags.details);
        }
        if self.flags.multi_select {
            v["multi_select"] = json!(true);
            v["checked"] = json!(self.flags.checked);
        }
        if let Some(p) = &self.payload {
            v["payload"] = json!(p);
        }
        v
    }

    fn fingerprint(&self) -> (String, Vec<String>) {
        (self.message.clone(), self.options.clone())
    }
}

/// A card as a client raises it (`cards.raise`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Raise {
    pub kind: Option<CardKind>,
    pub pane: String,
    pub worktree_path: String,
    pub branch: String,
    pub project: String,
    pub message: String,
    pub options: Vec<String>,
    pub payload: Option<String>,
}

/// One input to a pane, in order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Input {
    /// Raw bytes (text, or a key's escape sequence).
    Bytes(String),
    /// Return, as a write of its own after a short pause: a TUI reads a
    /// `\r` in the same burst as pasted text as a newline, not a submit.
    Submit,
}

/// What answering a card asks of the caller.
#[derive(Clone, Debug, PartialEq)]
pub enum Answer {
    /// Press these in the card's pane.
    Keys { pane: String, inputs: Vec<Input>, confirm_review: bool },
    /// Not the core's to perform (approval, proposal, report): hand the
    /// picked option to whoever raised the card.
    Raised { card: Box<Card>, option: String },
}

/// How long a card that left can come back as the same ask: a viewport can
/// miss a dialog for a frame while it still blocks the agent, and that must
/// not pop the island and send Telegram the question again.
const REAPPEARANCE_GRACE: f64 = 60.0 * 60.0;
const MAX_QUESTION_CHARS: usize = 200;
const MAX_SUMMARY_CHARS: usize = 700;

const KEY_UP: &str = "\x1b[A";
const KEY_DOWN: &str = "\x1b[B";
const KEY_RIGHT: &str = "\x1b[C";

/// What a card that left showed, when it left, and when it was fresh.
type Absent = ((String, Vec<String>), Timestamp, Timestamp);

#[derive(Default)]
pub struct Cards {
    cards: Vec<Card>,
    next: u64,
    /// Cards that left recently, by key: what they showed, when, and when
    /// they were fresh.
    absent: HashMap<String, Absent>,
}

impl Cards {
    pub fn new() -> Self {
        Self::default()
    }

    /// Oldest first.
    pub fn list(&self) -> &[Card] {
        &self.cards
    }

    pub fn get(&self, id: &str) -> Option<&Card> {
        self.cards.iter().find(|c| c.id == id)
    }

    pub fn has_pane(&self, pane: &str) -> bool {
        !pane.is_empty() && self.cards.iter().any(|c| c.pane == pane)
    }

    pub fn to_json(&self) -> Vec<Value> {
        self.cards.iter().map(Card::to_json).collect()
    }

    /// Cards for one outcome: questions and suggestions raised, stale ones
    /// cleared (`FirstMateCoordinator.handle`). True when anything changed.
    pub fn observe(&mut self, o: &Outcome, now: Timestamp) -> bool {
        let pane = o.info.id.as_str();
        let mut changed = match &o.event.kind {
            EventKind::UserPrompt { .. } => self.remove_where(|c| c.kind == CardKind::Suggestion && c.pane == pane, now),
            // The agent moved past its question (answered in the TUI).
            // AskUserQuestion's own tool start is decoded as a Question, so it
            // cannot clear itself.
            EventKind::ToolUse { .. } | EventKind::AgentStopped { .. } => {
                self.remove_where(|c| c.kind.is_question() && c.pane == pane, now)
            }
            // A dialog found on screen went away.
            EventKind::ScreenObserved { .. } if o.new_status != AgentStatus::Waiting => {
                self.remove_where(|c| c.kind.is_question() && c.pane == pane, now)
            }
            _ => false,
        };
        let i = &o.info;
        let base = |kind, message: String, options: Vec<String>| Card {
            id: String::new(),
            kind,
            pane: i.id.clone(),
            alias: i.alias.clone(),
            worktree_path: i.worktree_path.clone(),
            branch: i.branch.clone(),
            project: i.project.clone(),
            message,
            options,
            followups: Vec::new(),
            flags: QuestionFlags::default(),
            payload: None,
            created_at: now,
            fresh_at: now,
        };
        match &o.event.kind {
            EventKind::Question { prompt, options, followups, flags } if !options.is_empty() => {
                let kind = if o.event.source == EventSource::Scan { CardKind::Choice } else { CardKind::Question };
                let mut card = base(kind, prompt.chars().take(MAX_QUESTION_CHARS).collect(), options.clone());
                card.followups = followups.clone();
                card.flags = flags.clone();
                changed |= self.upsert(card, now);
            }
            EventKind::Suggest { options } if !options.is_empty() => {
                let summary = suggestion_summary(&i.last_assistant_message, &i.last_message);
                changed |= self.upsert(base(CardKind::Suggestion, summary, options.clone()), now);
            }
            _ => {}
        }
        // Once the agent has exited, every card it left is stale. Last, so a
        // suggestion arriving in the same outcome cannot survive it.
        if o.new_status == AgentStatus::Exited {
            changed |= self.drop_pane(pane, now);
        }
        changed
    }

    /// Late assistant prose for a pane's suggestion whose summary is tool
    /// chrome (Cursor's `afterAgentResponse` lands after the options). Never
    /// replaces a real summary, and does not make the card fresh.
    pub fn refresh_suggestion(&mut self, pane: &str, prose: &str) -> bool {
        let summary = summary_text(prose);
        if summary.is_empty() {
            return false;
        }
        let mut changed = false;
        for c in &mut self.cards {
            if c.kind == CardKind::Suggestion && c.pane == pane && is_junk_summary(&c.message) {
                c.message = summary.clone();
                changed = true;
            }
        }
        changed
    }

    /// A client's card (an integration report, First Mate's asks). Returns
    /// its id.
    pub fn raise(&mut self, r: Raise, now: Timestamp) -> Option<String> {
        let kind = r.kind?;
        let card = Card {
            id: String::new(),
            kind,
            pane: r.pane,
            alias: None,
            worktree_path: r.worktree_path,
            branch: r.branch,
            project: r.project,
            message: r.message,
            options: r.options,
            followups: Vec::new(),
            flags: QuestionFlags::default(),
            payload: r.payload,
            created_at: now,
            fresh_at: now,
        };
        let key = card.key();
        self.upsert(card, now);
        self.cards.iter().find(|c| c.key() == key).map(|c| c.id.clone())
    }

    pub fn remove(&mut self, id: &str, now: Timestamp) -> bool {
        self.remove_where(|c| c.id == id, now)
    }

    /// A pane that is gone (closed, or its agent exited) takes its cards.
    /// Worktree and app cards carry no pane and are spared.
    pub fn drop_pane(&mut self, pane: &str, now: Timestamp) -> bool {
        !pane.is_empty() && self.remove_where(|c| c.pane == pane, now)
    }

    /// A deleted worktree takes every card in it.
    pub fn drop_worktree(&mut self, path: &str, now: Timestamp) -> bool {
        !path.is_empty() && self.remove_where(|c| c.worktree_path == path, now)
    }

    /// Answer a card with one of its labels. `screen` is what the pane shows
    /// now, for finding the dialog's cursor. The queue moves on at once (the
    /// card goes, ticks, or steps to the next question); the caller presses
    /// the keys.
    pub fn answer(&mut self, id: &str, label: &str, screen: Option<&str>, now: Timestamp) -> Result<Answer, String> {
        let card = self.get(id).cloned().ok_or_else(|| "no such card".to_string())?;
        let labels = card.labels();
        let tapped = labels.iter().position(|l| l == label).ok_or_else(|| format!("not an option: {label}"))?;
        let selected = || screen.and_then(selected_row);
        match card.kind {
            CardKind::Approval | CardKind::Proposal | CardKind::Report => {
                self.remove(id, now);
                Ok(Answer::Raised { card: Box::new(card), option: label.to_string() })
            }
            CardKind::Suggestion => {
                self.remove(id, now);
                Ok(Answer::Keys { pane: card.pane, inputs: vec![Input::Bytes(label.to_string()), Input::Submit], confirm_review: false })
            }
            CardKind::Choice => {
                self.remove(id, now);
                Ok(Answer::Keys { pane: card.pane.clone(), inputs: arrows(tapped, selected().unwrap_or(0)), confirm_review: false })
            }
            CardKind::Question => {
                let count = card.options.len();
                if card.flags.multi_select && tapped == count {
                    let confirm = self.advance(&card, now);
                    return Ok(Answer::Keys { pane: card.pane, inputs: vec![Input::Bytes(KEY_RIGHT.into())], confirm_review: confirm });
                }
                let inputs = arrows(tapped, selected().unwrap_or(card.flags.cursor));
                if !card.flags.multi_select {
                    let confirm = self.advance(&card, now);
                    return Ok(Answer::Keys { pane: card.pane, inputs, confirm_review: confirm });
                }
                if let Some(c) = self.cards.iter_mut().find(|c| c.id == id) {
                    if let Some(at) = c.flags.checked.iter().position(|&i| i == tapped) {
                        c.flags.checked.remove(at);
                    } else {
                        c.flags.checked.push(tapped);
                        c.flags.checked.sort_unstable();
                    }
                    c.flags.cursor = tapped;
                }
                Ok(Answer::Keys { pane: card.pane, inputs, confirm_review: false })
            }
        }
    }

    /// The question was answered: the next one of a multi-question ask takes
    /// its place, or the card goes. True when the dialog will now show its
    /// review page, which wants a Return once it is up.
    fn advance(&mut self, card: &Card, now: Timestamp) -> bool {
        self.remove(&card.id, now);
        let Some((next, rest)) = card.followups.split_first() else {
            return card.flags.review_after;
        };
        let mut c = card.clone();
        c.id = String::new();
        c.message = next.prompt.clone();
        c.options = next.options.clone();
        c.flags = next.flags.clone();
        c.followups = rest.to_vec();
        c.fresh_at = now;
        self.upsert(c, now);
        false
    }

    /// Replace on the same key, keeping arrival order (a replacement is a
    /// new arrival). True when anything changed.
    fn upsert(&mut self, mut card: Card, now: Timestamp) -> bool {
        let key = card.key();
        self.absent.retain(|_, (_, at, _)| now - *at < REAPPEARANCE_GRACE);
        if let Some(idx) = self.cards.iter().position(|c| c.key() == key) {
            let old = self.cards.remove(idx);
            card.id = old.id.clone();
            card.created_at = old.created_at;
            if !is_fresh(&card, &old.fingerprint()) {
                card.fresh_at = old.fresh_at;
            }
            let same = card == old;
            self.cards.push(card);
            return !same || idx + 1 != self.cards.len();
        }
        // A hook question that comes back is a new AskUserQuestion call, not
        // a frame of flicker, so only other cards check the grace.
        if card.kind != CardKind::Question {
            if let Some((fp, _, fresh_at)) = self.absent.get(&key) {
                if !is_fresh(&card, fp) {
                    card.fresh_at = *fresh_at;
                }
            }
        }
        self.absent.remove(&key);
        self.next += 1;
        card.id = format!("c-{}", self.next);
        self.cards.push(card);
        true
    }

    fn remove_where(&mut self, pred: impl Fn(&Card) -> bool, now: Timestamp) -> bool {
        let before = self.cards.len();
        let mut kept = Vec::with_capacity(before);
        for c in std::mem::take(&mut self.cards) {
            if pred(&c) {
                self.absent.insert(c.key(), (c.fingerprint(), now, c.fresh_at));
            } else {
                kept.push(c);
            }
        }
        self.cards = kept;
        self.cards.len() != before
    }
}

/// A card is fresh against what was shown when its options changed, or its
/// summary was rewritten into something other than a late prose upgrade.
fn is_fresh(card: &Card, seen: &(String, Vec<String>)) -> bool {
    if seen.1 != card.options {
        return true;
    }
    if seen.0 == card.message {
        return false;
    }
    !is_junk_summary(&seen.0)
}

/// Down or up from the dialog's cursor to the row, then Return.
fn arrows(row: usize, from: usize) -> Vec<Input> {
    let key = if row >= from { KEY_DOWN } else { KEY_UP };
    let mut out: Vec<Input> = (0..row.abs_diff(from)).map(|_| Input::Bytes(key.into())).collect();
    out.push(Input::Submit);
    out
}

/// The 0-based row the choice list's cursor is on, when one is on screen.
fn selected_row(screen: &str) -> Option<usize> {
    let lines: Vec<&str> = screen.lines().collect();
    let tail = &lines[lines.len().saturating_sub(25)..];
    let mut rows: Vec<bool> = Vec::new();
    for l in tail {
        let t = l.trim_start();
        let (marked, rest) = match t.chars().next() {
            Some(c @ ('❯' | '›' | '>')) => (true, t[c.len_utf8()..].trim_start()),
            _ => (false, t),
        };
        let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
        if digits.is_empty() || !rest[digits.len()..].starts_with(". ") {
            continue;
        }
        if digits == "1" {
            rows.clear();
        }
        if digits.parse::<usize>().ok() == Some(rows.len() + 1) {
            rows.push(marked);
        }
    }
    rows.iter().position(|&m| m)
}

/// The text shown above a suggestion's options: the agent's prose, never
/// tool chrome.
pub fn suggestion_summary(last_assistant: &str, last_message: &str) -> String {
    let prose = summary_text(last_assistant);
    if !prose.is_empty() {
        return prose;
    }
    summary_text(last_message)
}

fn summary_text(raw: &str) -> String {
    let stripped: String = raw.split('\n').filter(|l| !l.contains("::seahelm-suggest::")).collect::<Vec<_>>().join("\n");
    let stripped = stripped.trim();
    if is_junk_summary(stripped) {
        return String::new();
    }
    stripped.chars().take(MAX_SUMMARY_CHARS).collect()
}

/// Tool or UI chrome rather than the agent's prose.
pub fn is_junk_summary(s: &str) -> bool {
    let t = s.trim();
    if t.is_empty() || t.to_lowercase().contains("seahelm-suggest") {
        return true;
    }
    let lower = t.to_lowercase();
    if ["shell", "bash", "zsh", "tool", "command"].contains(&lower.as_str()) {
        return true;
    }
    use AgentType::*;
    [Brew, Btop, Top, Htop, Docker, Npm, Yarn, Make, Cargo, Go, Python, Pip, ShellCommand, Unknown]
        .iter()
        .any(|a| a.display_name().eq_ignore_ascii_case(t))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pane::PaneInfo;
    use seahelm_core_types::NormalizedEvent;

    fn outcome(pane: &str, source: EventSource, kind: EventKind, new_status: AgentStatus) -> Outcome {
        let mut info = PaneInfo::new(pane.into(), None, "/w/a".into(), String::new(), String::new(), None);
        info.last_assistant_message = "Done. Tests pass.".into();
        info.status = new_status;
        Outcome {
            info,
            status_changed: false,
            old_status: AgentStatus::Running,
            new_status,
            hold_seconds: 0.0,
            is_completion_signal: false,
            event: NormalizedEvent { pane: pane.into(), source, kind },
            seq: 0,
        }
    }

    fn hook() -> EventSource {
        EventSource::Hook("claude-code".into())
    }

    fn suggest(pane: &str, options: &[&str]) -> Outcome {
        let kind = EventKind::Suggest { options: options.iter().map(|s| s.to_string()).collect() };
        outcome(pane, hook(), kind, AgentStatus::Idle)
    }

    fn question(pane: &str, source: EventSource, options: &[&str], flags: QuestionFlags, followups: Vec<QuestionSpec>) -> Outcome {
        let kind = EventKind::Question {
            prompt: "Pick one".into(),
            options: options.iter().map(|s| s.to_string()).collect(),
            followups,
            flags,
        };
        outcome(pane, source, kind, AgentStatus::Waiting)
    }

    fn prompt(pane: &str) -> Outcome {
        outcome(pane, hook(), EventKind::UserPrompt { text: "go".into() }, AgentStatus::Running)
    }

    #[test]
    fn a_suggestion_becomes_a_card_with_the_agents_prose() {
        let mut q = Cards::new();
        assert!(q.observe(&suggest("p1", &["build", "ship"]), 1.0));
        let c = &q.list()[0];
        assert_eq!((c.kind, c.message.as_str(), c.options.len()), (CardKind::Suggestion, "Done. Tests pass.", 2));
        assert_eq!(c.id, "c-1");
    }

    #[test]
    fn a_newer_suggestion_from_the_pane_replaces_the_older_in_place() {
        let mut q = Cards::new();
        q.observe(&suggest("p1", &["a"]), 1.0);
        q.observe(&suggest("p2", &["x"]), 2.0);
        q.observe(&suggest("p1", &["b"]), 3.0);
        assert_eq!(q.list().len(), 2);
        let c = q.list().last().unwrap();
        assert_eq!((c.id.as_str(), c.options[0].as_str(), c.fresh_at), ("c-1", "b", 3.0));
    }

    #[test]
    fn the_same_suggestion_again_is_not_fresh() {
        let mut q = Cards::new();
        q.observe(&suggest("p1", &["a"]), 1.0);
        q.observe(&suggest("p1", &["a"]), 5.0);
        assert_eq!(q.list()[0].fresh_at, 1.0);
    }

    #[test]
    fn prompting_the_pane_clears_its_suggestion_only() {
        let mut q = Cards::new();
        q.observe(&suggest("p1", &["a"]), 1.0);
        q.observe(&suggest("p2", &["b"]), 1.0);
        assert!(q.observe(&prompt("p1"), 2.0));
        assert_eq!(q.list().len(), 1);
        assert_eq!(q.list()[0].pane, "p2");
    }

    #[test]
    fn a_tool_use_or_stop_clears_the_panes_question() {
        let mut q = Cards::new();
        q.observe(&question("p1", hook(), &["a", "b"], QuestionFlags::default(), vec![]), 1.0);
        let stop = outcome("p1", hook(), EventKind::AgentStopped { success: true }, AgentStatus::Idle);
        assert!(q.observe(&stop, 2.0));
        assert!(q.list().is_empty());
    }

    #[test]
    fn a_screen_choice_is_a_choice_and_clears_when_the_screen_stops_waiting() {
        let mut q = Cards::new();
        q.observe(&question("p1", EventSource::Scan, &["Yes", "No"], QuestionFlags::default(), vec![]), 1.0);
        assert_eq!(q.list()[0].kind, CardKind::Choice);
        let still = scan("p1", AgentStatus::Waiting);
        assert!(!q.observe(&still, 2.0));
        assert!(q.observe(&scan("p1", AgentStatus::Running), 3.0));
        assert!(q.list().is_empty());
    }

    fn scan(pane: &str, status: AgentStatus) -> Outcome {
        let kind = EventKind::ScreenObserved {
            status,
            message: String::new(),
            activity: vec![],
            command_line: None,
            agent_type: AgentType::ClaudeCode,
            round_duration: 0.0,
            tasks: vec![],
            background_busy: false,
        };
        outcome(pane, EventSource::Scan, kind, status)
    }

    #[test]
    fn a_choice_that_flickers_back_is_not_fresh_but_gets_a_new_id() {
        let mut q = Cards::new();
        q.observe(&question("p1", EventSource::Scan, &["Yes", "No"], QuestionFlags::default(), vec![]), 1.0);
        q.observe(&scan("p1", AgentStatus::Running), 2.0);
        q.observe(&question("p1", EventSource::Scan, &["Yes", "No"], QuestionFlags::default(), vec![]), 3.0);
        let c = &q.list()[0];
        assert_eq!((c.id.as_str(), c.fresh_at), ("c-2", 1.0));
    }

    #[test]
    fn a_hook_question_asked_again_is_fresh() {
        let mut q = Cards::new();
        q.observe(&question("p1", hook(), &["a", "b"], QuestionFlags::default(), vec![]), 1.0);
        q.observe(&outcome("p1", hook(), EventKind::AgentStopped { success: true }, AgentStatus::Idle), 2.0);
        q.observe(&question("p1", hook(), &["a", "b"], QuestionFlags::default(), vec![]), 3.0);
        assert_eq!(q.list()[0].fresh_at, 3.0);
    }

    #[test]
    fn an_exited_agent_takes_its_cards_but_not_worktree_cards() {
        let mut q = Cards::new();
        q.observe(&suggest("p1", &["a"]), 1.0);
        q.raise(Raise { kind: Some(CardKind::Report), worktree_path: "/w/a".into(), message: "conflicts".into(), options: vec!["Discard".into()], ..Raise::default() }, 1.0);
        let exited = outcome("p1", EventSource::Scan, EventKind::AgentStopped { success: true }, AgentStatus::Exited);
        q.observe(&exited, 2.0);
        assert_eq!(q.list().len(), 1);
        assert_eq!(q.list()[0].kind, CardKind::Report);
        assert!(q.drop_worktree("/w/a", 3.0));
    }

    #[test]
    fn late_prose_upgrades_a_chrome_summary_without_making_it_fresh() {
        let mut q = Cards::new();
        let mut o = suggest("p1", &["a"]);
        o.info.last_assistant_message = "Shell".into();
        o.info.last_message = "seahelm-suggest a".into();
        q.observe(&o, 1.0);
        assert_eq!(q.list()[0].message, "");
        assert!(q.refresh_suggestion("p1", "Here is what I did.\n::seahelm-suggest:: a"));
        assert_eq!(q.list()[0].message, "Here is what I did.");
        assert!(!q.refresh_suggestion("p1", "Something else"));
        assert_eq!(q.list()[0].fresh_at, 1.0);
    }

    #[test]
    fn answering_a_suggestion_types_the_option_and_submits() {
        let mut q = Cards::new();
        q.observe(&suggest("p1", &["run tests"]), 1.0);
        let a = q.answer("c-1", "run tests", None, 2.0).unwrap();
        assert_eq!(a, Answer::Keys { pane: "p1".into(), inputs: vec![Input::Bytes("run tests".into()), Input::Submit], confirm_review: false });
        assert!(q.list().is_empty());
        assert!(q.answer("c-1", "run tests", None, 3.0).is_err());
    }

    #[test]
    fn answering_a_choice_moves_from_the_cursor_on_screen() {
        let mut q = Cards::new();
        q.observe(&question("p1", EventSource::Scan, &["Yes", "Always", "No"], QuestionFlags::default(), vec![]), 1.0);
        let screen = "Do you want to proceed?\n  1. Yes\n❯ 2. Always\n  3. No\n";
        let a = q.answer("c-1", "Yes", Some(screen), 2.0).unwrap();
        let Answer::Keys { inputs, .. } = a else { panic!() };
        assert_eq!(inputs, vec![Input::Bytes(KEY_UP.into()), Input::Submit]);
    }

    #[test]
    fn a_multi_question_ask_steps_to_the_next_then_confirms_review() {
        let mut q = Cards::new();
        let review = QuestionFlags { review_after: true, ..QuestionFlags::default() };
        let next = QuestionSpec { prompt: "(2/2) Second".into(), options: vec!["x".into(), "y".into()], flags: review.clone() };
        q.observe(&question("p1", hook(), &["a", "b"], QuestionFlags::default(), vec![next]), 1.0);
        let a = q.answer("c-1", "b", None, 2.0).unwrap();
        assert_eq!(a, Answer::Keys { pane: "p1".into(), inputs: vec![Input::Bytes(KEY_DOWN.into()), Input::Submit], confirm_review: false });
        let c = &q.list()[0];
        assert_eq!((c.message.as_str(), c.id.as_str()), ("(2/2) Second", "c-2"));
        let Answer::Keys { confirm_review, .. } = q.answer("c-2", "x", None, 3.0).unwrap() else { panic!() };
        assert!(confirm_review);
        assert!(q.list().is_empty());
    }

    /// Claude's dialog shows a tab title and a line under each option; the card
    /// carries both, and the next question of the ask brings its own.
    #[test]
    fn a_question_card_carries_header_and_details_per_question() {
        let mut q = Cards::new();
        let first = QuestionFlags {
            header: "Customer".into(),
            details: vec!["closing the books".into(), String::new()],
            ..QuestionFlags::default()
        };
        let next = QuestionSpec {
            prompt: "(2/2) Second".into(),
            options: vec!["x".into(), "y".into()],
            flags: QuestionFlags { header: "Requester".into(), review_after: true, ..QuestionFlags::default() },
        };
        q.observe(&question("p1", hook(), &["a", "b"], first, vec![next]), 1.0);
        let v = q.list()[0].to_json();
        assert_eq!(v["header"], json!("Customer"));
        assert_eq!(v["details"], json!(["closing the books", ""]));

        q.answer("c-1", "a", None, 2.0).unwrap();
        let v = q.list()[0].to_json();
        assert_eq!(v["header"], json!("Requester"));
        assert!(v.get("details").is_none(), "the second question has no descriptions");
    }

    #[test]
    fn a_multi_select_tap_ticks_and_done_leaves() {
        let mut q = Cards::new();
        let flags = QuestionFlags { multi_select: true, review_after: true, ..QuestionFlags::default() };
        q.observe(&question("p1", hook(), &["a", "b", "c"], flags, vec![]), 1.0);
        assert_eq!(q.list()[0].labels(), vec!["☐ a", "☐ b", "☐ c", DONE_LABEL]);
        let Answer::Keys { inputs, .. } = q.answer("c-1", "☐ c", None, 2.0).unwrap() else { panic!() };
        assert_eq!(inputs.len(), 3);
        assert_eq!(q.list()[0].labels()[2], "☑ c");
        // The cursor is on c now: b is one up.
        let Answer::Keys { inputs, .. } = q.answer("c-1", "☐ b", None, 3.0).unwrap() else { panic!() };
        assert_eq!(inputs, vec![Input::Bytes(KEY_UP.into()), Input::Submit]);
        let a = q.answer("c-1", DONE_LABEL, None, 4.0).unwrap();
        assert_eq!(a, Answer::Keys { pane: "p1".into(), inputs: vec![Input::Bytes(KEY_RIGHT.into())], confirm_review: true });
        assert!(q.list().is_empty());
    }

    #[test]
    fn a_raised_card_hands_the_answer_back() {
        let mut q = Cards::new();
        let id = q
            .raise(Raise { kind: Some(CardKind::Approval), message: "Delete feat-x".into(), options: vec!["Approve".into(), "Reject".into()], payload: Some("a-1".into()), ..Raise::default() }, 1.0)
            .unwrap();
        let Answer::Raised { card, option } = q.answer(&id, "Approve", None, 2.0).unwrap() else { panic!() };
        assert_eq!((card.payload.as_deref(), option.as_str()), (Some("a-1"), "Approve"));
    }

    #[test]
    fn junk_summaries() {
        assert!(is_junk_summary("Shell"));
        assert!(is_junk_summary("  docker "));
        assert!(is_junk_summary("ran seahelm-suggest a | b"));
        assert!(!is_junk_summary("All tests pass."));
    }
}
