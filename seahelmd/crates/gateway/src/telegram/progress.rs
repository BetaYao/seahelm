//! One live line per pane in the chats talking to it: what the agent is
//! doing while it does it. Pure: it takes pane events and timeline rows and
//! hands back effects (send, edit, delete, draft, wake me later) for the
//! adapter to perform.
//!
//! A **group** gets one message per bound pane, sent late, edited in place
//! and deleted when the turn ends: under the pane's name, the last few
//! things the agent said this turn. It never carries the answer; the
//! completion notice does, as its own message.
//!
//! A **private chat** gets a board instead, streamed with `sendMessageDraft`
//! (Telegram's typing preview, which never enters the history). A private
//! chat holds one draft, so the board is the whole fleet: the bound pane in
//! full with a Stop button, then a line per other pane running or waiting.
//! A draft fades about 12 s after the last call and whenever the bot sends
//! anything else there, so it is put up again every 8 s while anything runs.
//!
//! The group line is kept quiet: only chats bound to the pane, nothing until
//! a turn has run `GRACE` seconds, an edit at most every `MIN_EDIT_INTERVAL`
//! and never one that would put up the same words.

use std::collections::{HashMap, HashSet};

use super::format::truncated;
use super::session::is_private_chat;

pub const GRACE: f64 = 12.0;
pub const MIN_EDIT_INTERVAL: f64 = 3.0;
pub const FEED_ROWS: usize = 6;
pub const BOARD_REFRESH: f64 = 8.0;
pub const BOARD_THROTTLE: f64 = 1.5;
pub const BOARD_ROWS: usize = 8;
/// One draft per chat; the same id keeps its updates animated.
pub const BOARD_DRAFT_ID: i64 = 1;

#[derive(Debug, Clone, PartialEq)]
pub struct PaneMeta {
    pub handle: u64,
    pub project: String,
    pub branch: String,
}

/// One pane event, as much of it as matters here.
#[derive(Debug, Clone, PartialEq)]
pub struct PaneEvent {
    pub key: String,
    /// `Running`, `Idle`, `Waiting`, `Error`, `Exited`, `Unknown`.
    pub status: String,
    pub status_changed: bool,
    pub is_completion: bool,
}

impl PaneEvent {
    fn status_is(&self, s: &str) -> bool {
        self.status.eq_ignore_ascii_case(s)
    }

    /// Every way a turn can stop: a finish, an error, a question, an exit.
    pub fn ends_turn(&self) -> bool {
        if self.is_completion || self.status_is("exited") {
            return true;
        }
        self.status_changed && (self.status_is("idle") || self.status_is("waiting") || self.status_is("error"))
    }
}

/// Who listens: chats and the pane each is bound to, and the private chats
/// that hear the fleet unbound (the default chat).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct View {
    pub bound: Vec<(String, String)>,
    pub fleet_chats: Vec<String>,
}

impl View {
    /// Groups bound to the pane. A fleet listener is not one of them, and a
    /// private chat has the board.
    fn group_chats(&self, pane: &str) -> Vec<String> {
        let mut v: Vec<String> = self.bound.iter().filter(|(c, p)| p == pane && !is_private_chat(c)).map(|(c, _)| c.clone()).collect();
        v.sort();
        v
    }

    fn board_chats(&self) -> Vec<String> {
        let mut v: Vec<String> = self.bound.iter().map(|(c, _)| c.clone()).chain(self.fleet_chats.iter().cloned()).filter(|c| is_private_chat(c)).collect();
        v.sort();
        v.dedup();
        v
    }

    fn focus(&self, chat: &str) -> Option<&str> {
        self.bound.iter().find(|(c, _)| c == chat).map(|(_, p)| p.as_str())
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Wake {
    Report(String),
    Boards,
    BoardsHeartbeat,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// Send a new line; report its id back with `sent`.
    Send { pane: String, chat: String, text: String },
    Edit { chat: String, message: i64, text: String },
    Delete { chat: String, message: i64 },
    Draft { chat: String, text: String, can_stop: bool },
    Schedule { after: f64, wake: Wake },
}

#[derive(Debug, Default, Clone)]
struct Line {
    message: Option<i64>,
    sending: bool,
    text: String,
    edited_at: f64,
}

#[derive(Debug, Clone)]
struct BoardEntry {
    meta: PaneMeta,
    since: f64,
    waiting: bool,
}

#[derive(Debug, Default)]
pub struct Progress {
    lines: HashMap<String, HashMap<String, Line>>,
    turn_started: HashMap<String, f64>,
    panes: HashMap<String, PaneMeta>,
    feeds: HashMap<String, Vec<String>>,
    flushing: HashSet<String>,
    board: HashMap<String, BoardEntry>,
    board_sent: HashMap<String, f64>,
    board_scheduled: bool,
}

impl Progress {
    pub fn ingest_pane(&mut self, ev: &PaneEvent, meta: PaneMeta, view: &View, now: f64) -> Vec<Effect> {
        let mut out = Vec::new();
        self.track(ev, &meta, now, &mut out);
        let key = ev.key.clone();
        if ev.ends_turn() {
            self.turn_started.remove(&key);
            self.panes.remove(&key);
            self.feeds.remove(&key);
            if let Some(open) = self.lines.remove(&key) {
                for (chat, line) in open {
                    if let Some(message) = line.message {
                        out.push(Effect::Delete { chat, message });
                    }
                }
            }
        } else {
            let mut report = true;
            if !self.turn_started.contains_key(&key) {
                // Only work starts a turn: events keep arriving after one ends
                // (the reply streamed after Stop, a session closing), and one
                // of those opening a turn would leave a line nothing clears.
                if ev.status_is("running") {
                    self.turn_started.insert(key.clone(), now);
                    self.feeds.insert(key.clone(), Vec::new());
                } else {
                    report = false;
                }
            }
            if report {
                self.panes.insert(key.clone(), meta);
                self.report(&key, view, now, &mut out);
            }
        }
        self.refresh_boards(view, now, false, &mut out);
        out
    }

    /// A timeline row. Only a turn seen starting takes rows, so the reply
    /// that closed the last turn never opens the next.
    pub fn ingest_row(&mut self, pane: &str, kind: &str, text: Option<&str>, view: &View, now: f64) -> Vec<Effect> {
        let mut out = Vec::new();
        if !self.turn_started.contains_key(pane) {
            return out;
        }
        let Some(row) = row(kind, text) else { return out };
        let feed = self.feeds.entry(pane.to_string()).or_default();
        feed.push(row);
        if feed.len() > FEED_ROWS {
            let cut = feed.len() - FEED_ROWS;
            feed.drain(..cut);
        }
        self.report(pane, view, now, &mut out);
        self.refresh_boards(view, now, false, &mut out);
        out
    }

    pub fn wake(&mut self, wake: &Wake, view: &View, now: f64) -> Vec<Effect> {
        let mut out = Vec::new();
        match wake {
            Wake::Report(pane) => {
                self.flushing.remove(pane);
                self.report(pane, view, now, &mut out);
            }
            Wake::Boards => self.refresh_boards(view, now, false, &mut out),
            Wake::BoardsHeartbeat => {
                self.board_scheduled = false;
                self.refresh_boards(view, now, true, &mut out);
            }
        }
        out
    }

    /// A line's send came back. A turn that ended while it was in flight
    /// must not leave it behind.
    pub fn sent(&mut self, pane: &str, chat: &str, message: Option<i64>) -> Vec<Effect> {
        match self.lines.get_mut(pane).and_then(|l| l.get_mut(chat)) {
            Some(line) => {
                line.sending = false;
                line.message = message;
                Vec::new()
            }
            None => message.map(|m| vec![Effect::Delete { chat: chat.to_string(), message: m }]).unwrap_or_default(),
        }
    }

    fn report(&mut self, pane: &str, view: &View, now: f64, out: &mut Vec<Effect>) {
        let (Some(&started), Some(meta)) = (self.turn_started.get(pane), self.panes.get(pane)) else { return };
        if now - started < GRACE {
            return;
        }
        let chats = view.group_chats(pane);
        if chats.is_empty() {
            return;
        }
        let text = line_text(meta, self.feeds.get(pane).map(Vec::as_slice).unwrap_or_default(), started, now);
        let mut held_back = false;
        for chat in chats {
            if !self.post(&text, pane, &chat, now, out) {
                held_back = true;
            }
        }
        if held_back && self.flushing.insert(pane.to_string()) {
            out.push(Effect::Schedule { after: MIN_EDIT_INTERVAL, wake: Wake::Report(pane.to_string()) });
        }
    }

    /// False when the throttle held a changed line back.
    fn post(&mut self, text: &str, pane: &str, chat: &str, now: f64, out: &mut Vec<Effect>) -> bool {
        let line = self.lines.entry(pane.to_string()).or_default().entry(chat.to_string()).or_default();
        if line.sending {
            return text == line.text;
        }
        let Some(message) = line.message else {
            line.sending = true;
            line.text = text.to_string();
            // The send is the first paint.
            line.edited_at = now;
            out.push(Effect::Send { pane: pane.to_string(), chat: chat.to_string(), text: text.to_string() });
            return true;
        };
        if text == line.text {
            return true;
        }
        if now - line.edited_at < MIN_EDIT_INTERVAL {
            return false;
        }
        line.text = text.to_string();
        line.edited_at = now;
        out.push(Effect::Edit { chat: chat.to_string(), message, text: text.to_string() });
        true
    }

    fn track(&mut self, ev: &PaneEvent, meta: &PaneMeta, now: f64, out: &mut Vec<Effect>) {
        let key = &ev.key;
        if ev.status_is("running") && !ev.ends_turn() {
            match self.board.get_mut(key) {
                Some(e) if !e.waiting => e.meta = meta.clone(),
                _ => {
                    self.board.insert(key.clone(), BoardEntry { meta: meta.clone(), since: now, waiting: false });
                    // An agent thinking quietly sends nothing until the grace
                    // is over: look again then.
                    out.push(Effect::Schedule { after: GRACE, wake: Wake::Boards });
                }
            }
        } else if ev.status_is("waiting") {
            match self.board.get_mut(key) {
                Some(e) if e.waiting => e.meta = meta.clone(),
                _ => {
                    self.board.insert(key.clone(), BoardEntry { meta: meta.clone(), since: now, waiting: true });
                }
            }
        } else if ev.status_is("unknown") {
            // Detection lost the thread for a moment: neither started nor ended.
        } else {
            self.board.remove(key);
        }
    }

    /// Up while some pane has worked past the grace. A board of nothing but
    /// questions would be redrawn for as long as one sits unanswered, and the
    /// question card already said it.
    fn board_is_live(&self, now: f64) -> bool {
        self.board.values().any(|e| !e.waiting && now - e.since >= GRACE)
    }

    fn refresh_boards(&mut self, view: &View, now: f64, heartbeat: bool, out: &mut Vec<Effect>) {
        if !self.board_is_live(now) {
            return;
        }
        let mut held_back = false;
        for chat in view.board_chats() {
            if !heartbeat && self.board_sent.get(&chat).is_some_and(|last| now - last < BOARD_THROTTLE) {
                held_back = true;
                continue;
            }
            let (text, can_stop) = self.board_text(view.focus(&chat), now);
            out.push(Effect::Draft { chat: chat.clone(), text, can_stop });
            self.board_sent.insert(chat, now);
        }
        if !self.board_scheduled {
            self.board_scheduled = true;
            out.push(Effect::Schedule { after: if held_back { BOARD_THROTTLE } else { BOARD_REFRESH }, wake: Wake::BoardsHeartbeat });
        }
    }

    /// The board for one chat: its bound pane in full when that pane is
    /// working (the only one Stop can mean), then a line per other pane.
    fn board_text(&self, focus: Option<&str>, now: f64) -> (String, bool) {
        let mut blocks = Vec::new();
        let mut can_stop = false;
        if let Some((key, e)) = focus.and_then(|k| self.board.get(k).map(|e| (k, e))).filter(|(_, e)| !e.waiting) {
            blocks.push(line_text(&e.meta, self.feeds.get(key).map(Vec::as_slice).unwrap_or_default(), e.since, now));
            can_stop = true;
        }
        let mut others: Vec<&BoardEntry> = self.board.iter().filter(|(k, _)| Some(k.as_str()) != focus).map(|(_, e)| e).collect();
        // Questions first: they wait on the reader.
        others.sort_by(|a, b| b.waiting.cmp(&a.waiting).then(a.since.total_cmp(&b.since)).then(a.meta.handle.cmp(&b.meta.handle)));
        let rows: Vec<String> = others.iter().take(BOARD_ROWS).map(|e| board_row(&e.meta, e.waiting, e.since, now)).collect();
        if !rows.is_empty() {
            let mut list = rows.join("\n");
            if others.len() > rows.len() {
                list.push_str(&format!("\n… {} more", others.len() - rows.len()));
            }
            blocks.push(list);
        }
        (blocks.join("\n\n"), can_stop)
    }
}

pub fn board_row(meta: &PaneMeta, waiting: bool, since: f64, now: f64) -> String {
    let place = format!("#{} {}/{}", meta.handle, meta.project, meta.branch);
    if waiting {
        format!("❗ {place} · waiting for you")
    } else {
        format!("⏳ {place} · {}", elapsed(now - since))
    }
}

/// Which pane, for how long, then what the agent has stopped to say.
pub fn line_text(meta: &PaneMeta, feed: &[String], since: f64, now: f64) -> String {
    let head = format!("⏳ **#{} {}/{}** · {}", meta.handle, meta.project, meta.branch, elapsed(now - since));
    if feed.is_empty() {
        head
    } else {
        format!("{head}\n\n{}", feed.join("\n"))
    }
}

/// A timeline row as a line: what the agent *said*, nothing else. Tool calls
/// drowned the sentence they were context for, and cut to a phone's width
/// they say nothing you could act on.
pub fn row(kind: &str, text: Option<&str>) -> Option<String> {
    match kind {
        "assistant" | "thinking" => {
            let t = text.unwrap_or_default().trim();
            (!t.is_empty()).then(|| truncated(t, 200))
        }
        _ => None,
    }
}

/// Whole units only: a line that ticks over a decimal is an edit nobody reads.
pub fn elapsed(seconds: f64) -> String {
    let whole = seconds.max(0.0) as u64;
    if whole < 60 {
        return format!("{whole}s");
    }
    let minutes = whole / 60;
    if minutes < 60 {
        format!("{minutes}m")
    } else {
        format!("{}h{}m", minutes / 60, minutes % 60)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn meta(h: u64) -> PaneMeta {
        PaneMeta { handle: h, project: "repo".into(), branch: format!("b{h}") }
    }

    fn ev(key: &str, status: &str, changed: bool) -> PaneEvent {
        PaneEvent { key: key.into(), status: status.into(), status_changed: changed, is_completion: false }
    }

    fn group_view() -> View {
        View { bound: vec![("-100".into(), "p".into())], fleet_chats: vec![] }
    }

    #[test]
    fn a_group_line_appears_late_edits_and_goes() {
        let mut p = Progress::default();
        let v = group_view();
        let fx = p.ingest_pane(&ev("p", "Running", true), meta(3), &v, 0.0);
        assert!(!fx.iter().any(|e| matches!(e, Effect::Send { .. })), "{fx:?}");
        // Before the grace, rows collect silently.
        assert!(p.ingest_row("p", "assistant", Some("Looking at it."), &v, 5.0).is_empty());
        let fx = p.ingest_row("p", "tool", Some("Bash"), &v, 13.0);
        assert!(fx.is_empty(), "tool rows are not lines: {fx:?}");
        let fx = p.ingest_row("p", "assistant", Some("Found it."), &v, 13.0);
        let Some(Effect::Send { chat, text, .. }) = fx.first() else { panic!("{fx:?}") };
        assert_eq!(chat, "-100");
        assert_eq!(text, "⏳ **#3 repo/b3** · 13s\n\nLooking at it.\nFound it.");
        assert!(p.sent("p", "-100", Some(77)).is_empty());
        // Too soon for an edit: held back, and a wake is asked for.
        let fx = p.ingest_row("p", "assistant", Some("Fixing."), &v, 14.0);
        assert_eq!(fx, vec![Effect::Schedule { after: MIN_EDIT_INTERVAL, wake: Wake::Report("p".into()) }]);
        let fx = p.wake(&Wake::Report("p".into()), &v, 17.0);
        assert!(matches!(&fx[0], Effect::Edit { message: 77, text, .. } if text.ends_with("Fixing.")), "{fx:?}");
        let fx = p.ingest_pane(&PaneEvent { is_completion: true, ..ev("p", "Idle", true) }, meta(3), &v, 20.0);
        assert!(fx.contains(&Effect::Delete { chat: "-100".into(), message: 77 }));
    }

    #[test]
    fn a_line_sent_after_its_turn_ended_is_taken_back() {
        let mut p = Progress::default();
        let v = group_view();
        p.ingest_pane(&ev("p", "Running", true), meta(1), &v, 0.0);
        let fx = p.ingest_pane(&ev("p", "Running", false), meta(1), &v, 15.0);
        assert!(fx.iter().any(|e| matches!(e, Effect::Send { .. })));
        p.ingest_pane(&ev("p", "Idle", true), meta(1), &v, 16.0);
        assert_eq!(p.sent("p", "-100", Some(5)), vec![Effect::Delete { chat: "-100".into(), message: 5 }]);
    }

    #[test]
    fn events_after_a_turn_do_not_open_one() {
        let mut p = Progress::default();
        let v = group_view();
        p.ingest_pane(&ev("p", "Idle", false), meta(1), &v, 0.0);
        assert!(p.ingest_row("p", "assistant", Some("late"), &v, 20.0).is_empty());
    }

    #[test]
    fn private_chats_get_a_board_with_stop() {
        let mut p = Progress::default();
        let v = View { bound: vec![("5".into(), "p".into())], fleet_chats: vec!["5".into(), "6".into()] };
        let fx = p.ingest_pane(&ev("p", "Running", true), meta(1), &v, 0.0);
        assert!(fx.contains(&Effect::Schedule { after: GRACE, wake: Wake::Boards }));
        p.ingest_pane(&ev("q", "Waiting", true), meta(2), &v, 1.0);
        let fx = p.wake(&Wake::Boards, &v, 12.0);
        let drafts: Vec<_> = fx.iter().filter_map(|e| if let Effect::Draft { chat, text, can_stop } = e { Some((chat.clone(), text.clone(), *can_stop)) } else { None }).collect();
        assert_eq!(drafts.len(), 2);
        assert_eq!(drafts[0], ("5".into(), "⏳ **#1 repo/b1** · 12s\n\n❗ #2 repo/b2 · waiting for you".into(), true));
        assert!(!drafts[1].2);
        assert!(drafts[1].1.starts_with("❗ #2"));
        assert!(fx.contains(&Effect::Schedule { after: BOARD_REFRESH, wake: Wake::BoardsHeartbeat }));
        // The heartbeat redraws even inside the throttle.
        let fx = p.wake(&Wake::BoardsHeartbeat, &v, 12.5);
        assert_eq!(fx.iter().filter(|e| matches!(e, Effect::Draft { .. })).count(), 2);
        // Once nothing runs, the board stops.
        p.ingest_pane(&ev("p", "Idle", true), meta(1), &v, 20.0);
        assert!(p.wake(&Wake::BoardsHeartbeat, &v, 21.0).is_empty());
    }

    #[test]
    fn turn_edges_and_words() {
        assert!(ev("p", "Exited", false).ends_turn());
        assert!(ev("p", "Waiting", true).ends_turn());
        assert!(!ev("p", "Waiting", false).ends_turn());
        assert!(PaneEvent { is_completion: true, ..ev("p", "Running", false) }.ends_turn());
        assert_eq!(elapsed(59.9), "59s");
        assert_eq!(elapsed(125.0), "2m");
        assert_eq!(elapsed(3725.0), "1h2m");
        assert_eq!(row("user", Some("x")), None);
        assert_eq!(row("assistant", Some("  ")), None);
    }
}
