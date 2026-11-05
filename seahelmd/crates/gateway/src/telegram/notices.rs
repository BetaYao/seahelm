//! What a chat is told: pane notices, cards waiting on the user, and the
//! books that keep a card's buttons where they belong. Pure.

use std::collections::HashMap;

use serde_json::Value;

/// A status's glyph, as the app wrote it in notices.
pub fn status_icon(status: &str) -> &'static str {
    match status.to_ascii_lowercase().as_str() {
        "running" => "●",
        "idle" => "○",
        "waiting" => "◐",
        "error" => "✕",
        "exited" => "◻",
        _ => "?",
    }
}

pub fn notice_title(status: &str) -> String {
    match status.to_ascii_lowercase().as_str() {
        "idle" => "Finished successfully".into(),
        "waiting" => "Awaiting your response".into(),
        "error" => "Exited with error".into(),
        _ => status.to_string(),
    }
}

fn display_target(project: &str, branch: &str) -> String {
    if project.is_empty() {
        branch.to_string()
    } else {
        format!("{project} / {branch}")
    }
}

pub fn notice_subtitle(project: &str, branch: &str, pane_index: u64, pane_count: u64) -> String {
    let target = display_target(project, branch);
    if pane_count > 1 {
        format!("{target} [Pane {pane_index}]")
    } else {
        target
    }
}

/// A chat gets the agent's own words, whole, or a plain statement of what
/// happened — never an echo of the prompt the reader typed.
pub fn notice_body(status: &str, project: &str, branch: &str, last_message: &str, last_assistant_message: &str) -> String {
    let prose = last_assistant_message.trim();
    if !prose.is_empty() {
        return prose.to_string();
    }
    let target = display_target(project, branch);
    let fallback = match status.to_ascii_lowercase().as_str() {
        "waiting" => format!("{target} is waiting for your response"),
        "error" => format!("{target} encountered an error"),
        "idle" => format!("{target} completed its task"),
        _ => String::new(),
    };
    let trimmed = last_message.trim();
    if trimmed.is_empty() {
        return fallback;
    }
    // The screen's last line: paths shortened to their leaf, one line.
    let flat: Vec<String> = trimmed
        .split_whitespace()
        .map(|t| if t.starts_with('/') { t.trim_end_matches('/').rsplit('/').next().unwrap_or(t).to_string() } else { t.to_string() })
        .collect();
    let body = flat.join(" ");
    if body.chars().count() > 80 {
        body.chars().take(77).collect::<String>() + "..."
    } else {
        body
    }
}

/// A pane notice. In a chat the pane's `#n` leads the second line: a fleet
/// chat hears many panes, and the handle is what `/go` takes.
pub fn notice_text(icon: &str, title: &str, subtitle: &str, body: &str, handle: Option<u64>) -> String {
    let place = match handle {
        Some(h) => format!("#{h} {subtitle}"),
        None => subtitle.to_string(),
    };
    format!("{icon} **{title}**\n{place}\n\n{body}")
}

/// A card as the adapter reads the core's JSON.
#[derive(Debug, Clone, PartialEq)]
pub struct Card {
    pub id: String,
    pub kind: String,
    pub pane: String,
    pub project: String,
    pub branch: String,
    pub message: String,
    pub options: Vec<String>,
    pub labels: Vec<String>,
    pub multi_select: bool,
    pub checked: Vec<usize>,
    /// AskUserQuestion's tab title for the question, "" without.
    pub header: String,
    /// The line under each option, index for index with `options` ("" where
    /// one has none); empty when there are none.
    pub details: Vec<String>,
}

pub const DONE_LABEL: &str = "✔ Done";

impl Card {
    pub fn from_json(v: &Value) -> Option<Card> {
        let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or_default().to_string();
        let list = |k: &str| v.get(k).and_then(Value::as_array).map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect()).unwrap_or_default();
        let id = s("id");
        if id.is_empty() {
            return None;
        }
        let options: Vec<String> = list("options");
        let mut labels: Vec<String> = list("labels");
        if labels.is_empty() {
            labels = options.clone();
        }
        Some(Card {
            id,
            kind: s("kind"),
            pane: s("pane_session_key"),
            project: s("project"),
            branch: s("branch"),
            message: s("message"),
            options,
            labels,
            multi_select: v.get("multi_select").and_then(Value::as_bool).unwrap_or(false),
            checked: v.get("checked").and_then(Value::as_array).map(|a| a.iter().filter_map(|x| x.as_u64().map(|n| n as usize)).collect()).unwrap_or_default(),
            header: s("header").trim().to_string(),
            details: list("details").into_iter().map(|d: String| d.trim().to_string()).collect(),
        })
    }

    /// An agent's question or a screen choice: the pane is stopped on it.
    pub fn is_agent_question(&self) -> bool {
        self.kind == "question" || self.kind == "choice"
    }

    /// First Mate's own ask.
    pub fn is_first_mates(&self) -> bool {
        self.kind == "approval" || self.kind == "proposal"
    }

    /// Same card, same words: one Telegram message, however often it is
    /// rediscovered.
    pub fn packet_key(&self) -> String {
        format!("{}\u{1F}{}\u{1F}{}", self.id, self.message, self.options.join("\u{1E}"))
    }
}

/// The card as a chat message. The options are spelled out as well as drawn:
/// a button label is trimmed to a phone's width, and two options often
/// differ in the part that gets trimmed.
pub fn card_text(handle: Option<u64>, card: &Card) -> String {
    let (project, branch, message, options) = (card.project.as_str(), card.branch.as_str(), card.message.as_str(), &card.options);
    // The description under each option, as the agent's dialog shows it;
    // only when they line up with the options.
    let details: &[String] = if card.details.len() == options.len() { &card.details } else { &[] };
    let target = [project, branch].iter().filter(|s| !s.is_empty()).copied().collect::<Vec<_>>().join(" / ");
    let head = [handle.map(|h| format!("#{h}")), (!target.is_empty()).then_some(target)].into_iter().flatten().collect::<Vec<_>>().join(" · ");
    let mut lines = vec![format!("{} **Waiting on you**", status_icon("waiting"))];
    if !head.is_empty() {
        lines.push(head);
    }
    let prompt = message.trim();
    if !card.header.is_empty() {
        lines.push(format!("\n**{}**", card.header));
    }
    if !prompt.is_empty() {
        lines.push(if card.header.is_empty() { format!("\n{prompt}") } else { prompt.to_string() });
    }
    if !options.is_empty() {
        lines.push(String::new());
        for (i, o) in options.iter().enumerate() {
            lines.push(format!("{}. {o}", i + 1));
            if let Some(d) = details.get(i).filter(|d| !d.is_empty()) {
                lines.push(format!("    {d}"));
            }
        }
    }
    lines.join("\n")
}

/// What a tap answered, for the chat's "Picked …": Done on a multi-select
/// card stands for the rows ticked before it.
pub fn picked_summary(card: &Card, tapped: &str) -> String {
    if !card.multi_select || tapped != DONE_LABEL {
        return tapped.to_string();
    }
    let mut checked = card.checked.clone();
    checked.sort_unstable();
    let picked: Vec<&str> = checked.iter().filter_map(|i| card.options.get(*i).map(String::as_str)).collect();
    if picked.is_empty() {
        "nothing".into()
    } else {
        picked.join(", ")
    }
}

/// A message a chat holds.
#[derive(Debug, Clone, PartialEq)]
pub struct Ref {
    pub chat: String,
    pub message: i64,
    pub at: f64,
}

/// Which message in each chat an agent's next steps belong under: a
/// suggestion's options are added to the completion notice already on the
/// phone. One per chat per pane, the newest replacing the last; past the
/// window the chat has moved on.
#[derive(Debug, Default)]
pub struct NoticeBook {
    refs: HashMap<String, Vec<Ref>>,
}

pub const NOTICE_WINDOW: f64 = 180.0;

impl NoticeBook {
    pub fn record(&mut self, pane: &str, chat: &str, message: i64, now: f64) {
        if pane.is_empty() {
            return;
        }
        let list = self.refs.entry(pane.to_string()).or_default();
        list.retain(|r| r.chat != chat);
        list.push(Ref { chat: chat.to_string(), message, at: now });
    }

    pub fn recent(&self, pane: &str, now: f64) -> Vec<Ref> {
        self.refs.get(pane).map(|l| l.iter().filter(|r| now - r.at <= NOTICE_WINDOW).cloned().collect()).unwrap_or_default()
    }

    pub fn prune(&mut self, now: f64) {
        self.refs.retain(|_, l| {
            l.retain(|r| now - r.at <= NOTICE_WINDOW);
            !l.is_empty()
        });
    }
}

/// Which cards a chat has been shown, so it hears of a genuinely new ask and
/// not of one already up. Ids alone cannot say (a pane's next suggestion
/// reuses its card's id), so what the card shows is fingerprinted too.
#[derive(Debug, Default)]
pub struct SeenCards {
    seen: HashMap<String, (String, Vec<String>)>,
    /// A screen choice can drop out of the core's view for a frame while it
    /// still blocks the agent; its return is not a new card.
    recently_absent: HashMap<String, ((String, Vec<String>), f64)>,
}

pub const REAPPEARANCE_GRACE: f64 = 3600.0;

impl SeenCards {
    /// Record `cards` as the full set on offer; return the ones not shown yet.
    pub fn absorb(&mut self, cards: &[Card], now: f64) -> Vec<Card> {
        let incoming: Vec<&str> = cards.iter().map(|c| c.id.as_str()).collect();
        for (id, f) in &self.seen {
            if !incoming.contains(&id.as_str()) {
                self.recently_absent.insert(id.clone(), (f.clone(), now));
            }
        }
        self.recently_absent.retain(|_, (_, at)| now - *at < REAPPEARANCE_GRACE);
        let fp = |c: &Card| (c.message.clone(), c.options.clone());
        let fresh: Vec<Card> = cards
            .iter()
            .filter(|c| {
                if let Some(cur) = self.seen.get(&c.id) {
                    return *cur != fp(c);
                }
                // A question asked again is a new ask, even in the same words.
                if c.kind == "question" {
                    return true;
                }
                match self.recently_absent.get(&c.id) {
                    Some((f, _)) => *f != fp(c),
                    None => true,
                }
            })
            .cloned()
            .collect();
        self.seen = cards.iter().map(|c| (c.id.clone(), fp(c))).collect();
        for id in incoming {
            self.recently_absent.remove(id);
        }
        fresh
    }
}

/// Duplicate sends of one logical message (a card rediscovered before its
/// first send came back) stay one Telegram message.
#[derive(Debug, Default)]
pub struct PacketBook {
    in_flight: std::collections::HashSet<String>,
    delivered: HashMap<String, (i64, f64)>,
}

pub const PACKET_RETENTION: f64 = 3600.0;

#[derive(Debug, PartialEq)]
pub enum Packet {
    Send,
    /// Already on its way.
    Joined,
    Delivered(i64),
}

impl PacketBook {
    pub fn begin(&mut self, key: &str, now: f64) -> Packet {
        self.delivered.retain(|_, (_, at)| now - *at < PACKET_RETENTION);
        if let Some((id, _)) = self.delivered.get(key) {
            return Packet::Delivered(*id);
        }
        if !self.in_flight.insert(key.to_string()) {
            return Packet::Joined;
        }
        Packet::Send
    }

    /// Only a message Telegram accepted is remembered; a failure may try
    /// again on the next real event.
    pub fn finish(&mut self, key: &str, message: Option<i64>, now: f64) {
        self.in_flight.remove(key);
        if let Some(id) = message {
            self.delivered.insert(key.to_string(), (id, now));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn notice_text_puts_the_handle_on_line_two() {
        let t = notice_text("○", "Finished successfully", "repo / fix", "All green.", Some(7));
        assert_eq!(t, "○ **Finished successfully**\n#7 repo / fix\n\nAll green.");
        assert_eq!(notice_text("◐", "T", "s", "b", None), "◐ **T**\ns\n\nb");
        assert_eq!(notice_subtitle("repo", "fix", 2, 3), "repo / fix [Pane 2]");
        assert_eq!(notice_title("Idle"), "Finished successfully");
        assert_eq!(status_icon("Waiting"), "◐");
    }

    #[test]
    fn notice_body_prefers_the_agents_words() {
        assert_eq!(notice_body("Idle", "r", "b", "screen", "  Done.\nAll tests pass.  "), "Done.\nAll tests pass.");
        assert_eq!(notice_body("Idle", "r", "b", "", ""), "r / b completed its task");
        assert_eq!(notice_body("Error", "r", "b", "failed at /a/b/c.rs now", ""), "failed at c.rs now");
    }

    /// AskUserQuestion's tab title over the question and a line under each
    /// option, as in the agent's dialog.
    #[test]
    fn card_text_shows_header_and_descriptions() {
        let v = json!({"id": "c1", "kind": "question", "project": "repo", "branch": "fix",
                       "message": "Which customer?", "header": "Customer",
                       "options": ["Banana", "None"], "labels": ["Banana", "None"],
                       "details": ["closing the books", ""]});
        let c = Card::from_json(&v).unwrap();
        assert_eq!(
            card_text(None, &c),
            "◐ **Waiting on you**\nrepo / fix\n\n**Customer**\nWhich customer?\n\n1. Banana\n    closing the books\n2. None"
        );
        // Details that do not line up are left out.
        let mut odd = c.clone();
        odd.details = vec!["x".into()];
        assert!(!card_text(None, &odd).contains("    x"));
    }

    #[test]
    fn cards_read_the_core_shape() {
        let v = json!({"id": "c1", "kind": "question", "pane_session_key": "s-1", "project": "repo", "branch": "fix",
                       "message": "Proceed?", "options": ["Yes", "No"], "labels": ["☐ Yes", "☐ No", "✔ Done"], "multi_select": true, "checked": [1]});
        let c = Card::from_json(&v).unwrap();
        assert!(c.is_agent_question());
        assert_eq!(c.labels.len(), 3);
        assert_eq!(picked_summary(&c, DONE_LABEL), "No");
        assert_eq!(picked_summary(&c, "☐ Yes"), "☐ Yes");
        let text = card_text(Some(3), &c);
        assert_eq!(text, "◐ **Waiting on you**\n#3 · repo / fix\n\nProceed?\n\n1. Yes\n2. No");
        assert!(Card::from_json(&json!({"kind": "question"})).is_none());
    }

    #[test]
    fn notice_book_keeps_the_newest_per_chat() {
        let mut b = NoticeBook::default();
        b.record("p", "1", 10, 0.0);
        b.record("p", "1", 11, 5.0);
        b.record("p", "2", 12, 5.0);
        assert_eq!(b.recent("p", 6.0).iter().map(|r| r.message).collect::<Vec<_>>(), vec![11, 12]);
        assert!(b.recent("p", 5.0 + NOTICE_WINDOW + 1.0).is_empty());
        b.prune(1000.0);
        assert!(b.refs.is_empty());
    }

    fn card(id: &str, kind: &str, msg: &str) -> Card {
        Card { id: id.into(), kind: kind.into(), pane: "p".into(), project: String::new(), branch: String::new(), message: msg.into(), options: vec!["a".into()], labels: vec!["a".into()], multi_select: false, checked: vec![], header: String::new(), details: vec![] }
    }

    #[test]
    fn seen_cards_pop_once() {
        let mut s = SeenCards::default();
        assert_eq!(s.absorb(&[card("c", "choice", "m")], 0.0).len(), 1);
        assert!(s.absorb(&[card("c", "choice", "m")], 1.0).is_empty());
        // A choice that flickers away and back is not new…
        assert!(s.absorb(&[], 2.0).is_empty());
        assert!(s.absorb(&[card("c", "choice", "m")], 3.0).is_empty());
        // …but a question asked again is, and so is a changed card.
        assert!(s.absorb(&[], 4.0).is_empty());
        assert_eq!(s.absorb(&[card("c", "question", "m")], 5.0).len(), 1);
        assert_eq!(s.absorb(&[card("c", "question", "m2")], 6.0).len(), 1);
    }

    #[test]
    fn packet_book_coalesces() {
        let mut p = PacketBook::default();
        assert_eq!(p.begin("k", 0.0), Packet::Send);
        assert_eq!(p.begin("k", 0.1), Packet::Joined);
        p.finish("k", Some(9), 0.2);
        assert_eq!(p.begin("k", 1.0), Packet::Delivered(9));
        assert_eq!(p.begin("k", 0.2 + PACKET_RETENTION), Packet::Send);
        p.finish("k", None, 0.0);
        assert_eq!(p.begin("k", 0.0), Packet::Send);
    }
}
