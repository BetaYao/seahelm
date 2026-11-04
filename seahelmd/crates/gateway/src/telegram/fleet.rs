//! Following the core: pane notices to the chats that hear them, cards as
//! buttons, the progress line and board, First Mate's answers and actions.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;
use tokio::sync::broadcast::error::RecvError;

use super::api::Button;
use super::callbacks::Action;
use super::notices::{self, Card};
use super::progress::{Effect, PaneEvent, PaneMeta, View};
use super::rules::PaneRow;
use super::session;
use super::{default_chat, lock, Adapter};

/// First Mate's seahelmd session, the pane its turns end in.
const FIRST_MATE_SESSION: &str = "seahelm-first-mate";

/// The fleet as `pane.list` last said: each pane's `#n`, project, branch.
#[derive(Debug, Default)]
pub(super) struct PaneCache {
    metas: HashMap<String, PaneMeta>,
    fetched_at: f64,
    stale: bool,
}

fn pane_rows(list: &Value) -> Vec<(PaneRow, Option<PaneMeta>)> {
    let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or_default().to_string();
    list.get("panes")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .map(|p| {
                    let row = PaneRow { session_key: s(p, "pane_session_key"), pane_id: s(p, "pane_id"), worktree_path: s(p, "worktree_path"), project: s(p, "project") };
                    let meta = p.get("handle").and_then(Value::as_u64).map(|handle| PaneMeta { handle, project: s(p, "project"), branch: s(p, "branch") });
                    (row, meta)
                })
                .collect()
        })
        .unwrap_or_default()
}

impl Adapter {
    /// Ask the core for the fleet now, and keep its handles.
    pub(super) async fn refresh_panes(&self) -> Vec<PaneRow> {
        let Ok(list) = self.gw.core.call("pane.list", serde_json::json!({})).await else { return Vec::new() };
        let rows = pane_rows(&list);
        let mut cache = lock(&self.panes);
        cache.metas = rows.iter().filter_map(|(r, m)| m.clone().map(|m| (r.session_key.clone(), m))).collect();
        cache.fetched_at = crate::auth::now();
        cache.stale = false;
        rows.into_iter().map(|(r, _)| r).collect()
    }

    /// A pane's `#n` and place; None for a pane not in the fleet (or First
    /// Mate's, which has no handle).
    pub(super) async fn pane_meta(&self, key: &str) -> Option<PaneMeta> {
        let refresh = {
            let cache = lock(&self.panes);
            if let Some(m) = cache.metas.get(key).filter(|_| !cache.stale) {
                return Some(m.clone());
            }
            cache.stale || crate::auth::now() - cache.fetched_at > 1.0
        };
        if refresh {
            self.refresh_panes().await;
        }
        lock(&self.panes).metas.get(key).cloned()
    }

    /// Unbound fleet listeners: the default chat and the chat the last order
    /// came from.
    fn fleet_listeners(&self) -> Vec<String> {
        let mut v: Vec<String> = default_chat(&self.config()).into_iter().collect();
        if let Some(c) = lock(&self.shared).last_order_chat.clone() {
            if !v.contains(&c) {
                v.push(c);
            }
        }
        v
    }

    fn progress_view(&self) -> View {
        let st = self.gw.store();
        let bound = session::all(&st.state.chat_sessions)
            .into_iter()
            .filter_map(|s| Some((session::chat_of(&s.key)?.to_string(), s.bound_pane()?.to_string())))
            .collect();
        View { bound, fleet_chats: default_chat(&st.config.telegram).into_iter().collect() }
    }

    pub(super) async fn follow_events(self: Arc<Self>) {
        let mut rx = self.gw.core.events();
        loop {
            let ev = match rx.recv().await {
                Ok(ev) => ev,
                Err(RecvError::Lagged(n)) => {
                    eprintln!("seahelm-gateway: telegram: {n} core events skipped");
                    continue;
                }
                Err(RecvError::Closed) => return,
            };
            if self.live().is_none() {
                continue;
            }
            let kind = ev.get("type").and_then(Value::as_str).unwrap_or_default();
            match kind {
                "pane.status_changed" | "pane.updated" => self.pane_event(&ev, kind == "pane.status_changed").await,
                "pane.notice" => self.notice(&ev).await,
                "pane.registered" | "pane.closed" | "pane.rehomed" => lock(&self.panes).stale = true,
                "autopilot.audit" => self.audit(&ev),
                _ => {}
            }
        }
    }

    async fn pane_event(self: &Arc<Self>, ev: &Value, status_changed: bool) {
        let key = ev.get("pane_session_key").and_then(Value::as_str).unwrap_or_default().to_string();
        let is_completion = ev.get("is_completion").and_then(Value::as_bool).unwrap_or(false);
        if key == FIRST_MATE_SESSION {
            // First Mate's turn ended: its answer goes to the chats that asked.
            let answer = ev.get("final_message").and_then(Value::as_str).unwrap_or_default().trim().to_string();
            if is_completion && !answer.is_empty() {
                let targets = std::mem::take(&mut lock(&self.shared).first_mate_targets);
                for t in targets {
                    if let Some(chat) = session::chat_of(&t) {
                        self.say(chat, &format!("⎈ First Mate\n{answer}"));
                    }
                }
            }
            return;
        }
        if key.is_empty() {
            return;
        }
        let Some(meta) = self.pane_meta(&key).await else { return };
        let pe = PaneEvent { key, status: ev.get("status").and_then(Value::as_str).unwrap_or_default().to_string(), status_changed, is_completion };
        let view = self.progress_view();
        let fx = lock(&self.progress).ingest_pane(&pe, meta, &view, crate::auth::now());
        self.apply(fx);
    }

    pub(super) async fn follow_messages(self: Arc<Self>) {
        let mut rx = self.gw.core.messages();
        loop {
            let row = match rx.recv().await {
                Ok(r) => r,
                Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => return,
            };
            if self.live().is_none() {
                continue;
            }
            let s = |k: &str| row.get(k).and_then(Value::as_str).unwrap_or_default();
            let pane = s("pane_session_key");
            if pane.is_empty() {
                continue;
            }
            let view = self.progress_view();
            let fx = lock(&self.progress).ingest_row(pane, s("kind"), row.get("text").and_then(Value::as_str), &view, crate::auth::now());
            self.apply(fx);
        }
    }

    /// Perform what the progress reporter decided.
    fn apply(self: &Arc<Self>, fx: Vec<Effect>) {
        for e in fx {
            match e {
                Effect::Send { pane, chat, text } => {
                    let me = self.clone();
                    tokio::spawn(async move {
                        let id = me.send(&chat, &text, Vec::new()).await;
                        let more = lock(&me.progress).sent(&pane, &chat, id);
                        me.apply(more);
                    });
                }
                Effect::Edit { chat, message, text } => self.edit(&chat, message, &text),
                Effect::Delete { chat, message } => self.delete(&chat, message),
                Effect::Draft { chat, text, can_stop } => self.draft(&chat, &text, can_stop),
                Effect::Schedule { after, wake } => {
                    let me = self.clone();
                    tokio::spawn(async move {
                        tokio::time::sleep(Duration::from_secs_f64(after)).await;
                        let view = me.progress_view();
                        let more = lock(&me.progress).wake(&wake, &view, crate::auth::now());
                        me.apply(more);
                    });
                }
            }
        }
    }

    /// A pane notice the core decided on, to the chats that hear it.
    async fn notice(self: &Arc<Self>, n: &Value) {
        let s = |k: &str| n.get(k).and_then(Value::as_str).unwrap_or_default().to_string();
        let key = s("pane_session_key");
        // First Mate's answers go to the chats that asked (`pane_event`).
        if key == FIRST_MATE_SESSION {
            return;
        }
        let status = s("new_status");
        // A card for this pane already says it needs input, with buttons.
        if status.eq_ignore_ascii_case("waiting") && self.gw.core.cards().borrow().iter().any(|c| c.get("pane_session_key").and_then(Value::as_str) == Some(key.as_str())) {
            return;
        }
        let meta = if key.is_empty() { None } else { self.pane_meta(&key).await };
        let worktree = s("worktree_path");
        let (project, branch) = match &meta {
            Some(m) => (m.project.clone(), m.branch.clone()),
            None => (String::new(), worktree.trim_end_matches('/').rsplit('/').next().unwrap_or_default().to_string()),
        };
        let u = |k: &str| n.get(k).and_then(Value::as_u64).unwrap_or(1);
        let text = notices::notice_text(
            notices::status_icon(&status),
            &notices::notice_title(&status),
            &notices::notice_subtitle(&project, &branch, u("pane_index"), u("pane_count")),
            &notices::notice_body(&status, &project, &branch, &s("last_message"), &s("last_assistant_message")),
            meta.as_ref().map(|m| m.handle),
        );
        // The pane on screen at the desk: the fleet's listeners stay quiet
        // (a phone ping for what is already in view is noise). A chat bound
        // to the pane still hears it: its order's answer must reach it.
        let visible = n.get("is_target_visible").and_then(Value::as_bool).unwrap_or(false);
        let fleet = if visible { Vec::new() } else { self.fleet_listeners() };
        let chats = session::chats_to_notify(&self.gw.store().state.chat_sessions, (!key.is_empty()).then_some(key.as_str()), &fleet);
        for chat in chats {
            let me = self.clone();
            let (text, key) = (text.clone(), key.clone());
            tokio::spawn(async move {
                // Remembered so the agent's suggested next steps, a beat
                // behind, can be added to it as buttons.
                if let Some(id) = me.send(&chat, &text, Vec::new()).await {
                    lock(&me.shared).notice_book.record(&key, &chat, id, crate::auth::now());
                    let cards = me.gw.core.cards().borrow().clone();
                    me.publish_cards(&cards).await;
                }
            });
        }
    }

    /// What First Mate did on its own is worth a line on the phone; reads
    /// and deliveries are not.
    fn audit(&self, ev: &Value) {
        let entry = ev.get("entry").cloned().unwrap_or_default();
        if entry.get("kind").and_then(Value::as_str) != Some("action") {
            return;
        }
        let text = entry.get("text").and_then(Value::as_str).unwrap_or_default();
        if let Some(chat) = default_chat(&self.config()) {
            self.say(&chat, &format!("⎈ First Mate\n→ {text}"));
        }
    }

    pub(super) async fn follow_cards(self: Arc<Self>) {
        let mut rx = self.gw.core.cards();
        loop {
            if rx.changed().await.is_err() {
                return;
            }
            let cards = rx.borrow_and_update().clone();
            if self.live().is_some() {
                self.publish_cards(&cards).await;
            }
        }
    }

    /// One message per card, and only when there is something to say. A
    /// question (or First Mate's ask) is a stop and gets a message of its
    /// own; a suggestion's words were already sent as the completion
    /// notice, so its options are added to that notice — no notice, no
    /// buttons.
    pub(super) async fn publish_cards(self: &Arc<Self>, raw: &[Value]) {
        let cards: Vec<Card> = raw.iter().filter_map(Card::from_json).collect();
        let now = crate::auth::now();
        let mut to_send = Vec::new();
        {
            let mut sh = lock(&self.shared);
            // Cards that left the queue: take their buttons down.
            let gone: Vec<String> = sh.card_buttons.keys().filter(|id| !cards.iter().any(|c| &c.id == *id)).cloned().collect();
            for id in gone {
                for r in sh.card_buttons.remove(&id).unwrap_or_default() {
                    self.set_buttons(&r.chat, r.message, Vec::new());
                }
                sh.card_labels.remove(&id);
            }
            sh.notice_book.prune(now);
            // A multi-select question ticked from a chat: redraw its ticks.
            for c in cards.iter().filter(|c| c.multi_select) {
                let Some(refs) = sh.card_buttons.get(&c.id).cloned() else { continue };
                if sh.card_labels.get(&c.id) == Some(&c.labels) {
                    continue;
                }
                sh.card_labels.insert(c.id.clone(), c.labels.clone());
                let buttons = self.option_buttons(c, true);
                for r in refs {
                    self.set_buttons(&r.chat, r.message, buttons.clone());
                }
            }
            let attachable: Vec<Card> = cards
                .iter()
                .filter(|c| !c.options.is_empty() && (c.is_agent_question() || c.is_first_mates() || !sh.notice_book.recent(&c.pane, now).is_empty()))
                .cloned()
                .collect();
            for c in sh.seen_cards.absorb(&attachable, now) {
                if c.is_agent_question() || c.is_first_mates() {
                    sh.card_labels.insert(c.id.clone(), c.labels.clone());
                    to_send.push(c);
                } else {
                    let targets = sh.notice_book.recent(&c.pane, now);
                    let buttons = self.option_buttons(&c, false);
                    for t in &targets {
                        self.set_buttons(&t.chat, t.message, buttons.clone());
                    }
                    sh.card_buttons.insert(c.id.clone(), targets);
                }
            }
        }
        for c in to_send {
            self.send_card(c).await;
        }
    }

    /// A card that stops someone, as its own message. Not silenced by
    /// `/go`: binding routes a conversation, it does not say "don't tell me
    /// when the fleet stops", and a blocked agent never resolves itself.
    async fn send_card(self: &Arc<Self>, c: Card) {
        let mut chats = session::chats_bound_to(&self.gw.store().state.chat_sessions, &c.pane);
        chats.extend(self.fleet_listeners());
        chats.sort();
        chats.dedup();
        if chats.is_empty() {
            return;
        }
        let handle = if c.pane.is_empty() { None } else { self.pane_meta(&c.pane).await.map(|m| m.handle) };
        let text = notices::card_text(handle, &c.project, &c.branch, &c.message, &c.options);
        let buttons = self.option_buttons(&c, true);
        for chat in chats {
            let packet = format!("{chat}\u{1F}{}", c.packet_key());
            let now = crate::auth::now();
            if lock(&self.shared).packets.begin(&packet, now) != notices::Packet::Send {
                continue;
            }
            let me = self.clone();
            let (text, buttons, card) = (text.clone(), buttons.clone(), c.id.clone());
            tokio::spawn(async move {
                let id = me.send(&chat, &text, buttons).await;
                let mut sh = lock(&me.shared);
                sh.packets.finish(&packet, id, crate::auth::now());
                if let Some(id) = id {
                    sh.card_buttons.entry(card).or_default().push(notices::Ref { chat, message: id, at: crate::auth::now() });
                }
            });
        }
    }

    /// A card's options as buttons; `dismissable` adds a way to leave a
    /// question without answering it (not on a suggestion, where not
    /// tapping is declining). Minted once and shared by every chat.
    fn option_buttons(&self, c: &Card, dismissable: bool) -> Vec<Button> {
        let mut reg = lock(&self.callbacks);
        let mut out: Vec<Button> =
            c.labels.iter().enumerate().map(|(index, label)| Button { label: label.clone(), token: reg.mint(Action::CardOption { card: c.id.clone(), index }) }).collect();
        if dismissable {
            out.push(Button { label: "Leave it waiting".into(), token: reg.mint(Action::DismissCard { card: c.id.clone() }) });
        }
        out
    }

    /// Take one card's buttons down everywhere they were drawn.
    pub(super) fn retire_card_buttons(&self, card: &str) {
        let refs = lock(&self.shared).card_buttons.remove(card).unwrap_or_default();
        for r in refs {
            self.set_buttons(&r.chat, r.message, Vec::new());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_pane_list_rows() {
        let list = json!({"panes": [
            {"pane_session_key": "s-1", "pane_id": "A", "worktree_path": "/r/wt", "project": "repo", "branch": "fix", "handle": 4},
            {"pane_session_key": "seahelm-first-mate", "pane_id": "fm", "worktree_path": "/fm", "project": "", "branch": ""},
        ]});
        let rows = pane_rows(&list);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].1, Some(PaneMeta { handle: 4, project: "repo".into(), branch: "fix".into() }));
        assert_eq!(rows[1].1, None);
        assert_eq!(rows[0].0.pane_id, "A");
    }
}
