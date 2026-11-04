//! What comes in: messages (orders, `/start`, rule input), button taps, and
//! Stop under a draft.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};

use super::api::{Button, CallbackQuery, GenerationStopped, Message, User};
use super::callbacks::Action;
use super::session::{self, ChatSession};
use super::{inbound, lock, notices, rules, Adapter};
use crate::store::TelegramConfig;

const CORE_DOWN: &str = "seahelm-core is not running — commands are the core's. Try again in a moment.";

/// A core error that is the core not answering, not the core saying no.
fn core_unreachable(e: &crate::rpc::RpcError) -> bool {
    e.code == -32000 && e.message.starts_with("seahelm-core unavailable")
}

impl Adapter {
    pub(super) async fn handle_message(self: Arc<Self>, m: Message) {
        let cfg = self.config();
        let username = self.username();
        let bot_name = username.as_deref();
        // Media only for someone who can give an order: nothing else reads
        // it (rules match the caption), and a group the bot sits in would
        // otherwise have every stranger's image fetched onto this disk.
        let may_order = m.from.as_ref().is_some_and(|f| cfg.allows(f.id, f.username.as_deref()));
        let paths = if may_order { self.download_media(&m).await } else { Vec::new() };
        let text = inbound::compose_order_text(&paths, m.body());
        if text.is_empty() {
            return;
        }
        let chat = m.chat.id.to_string();

        // `/start` is Telegram's own front door (the Start button, and a
        // deep link carrying a pairing code). Answered here, never run.
        let start_src = inbound::strip_bot_mention(m.body().unwrap_or_default().trim(), bot_name);
        if let Some(payload) = inbound::start_payload(&start_src) {
            self.handle_start(&payload, &m, &cfg).await;
            return;
        }

        if let Some(order) = inbound::order(&m, &text, &cfg, bot_name) {
            lock(&self.shared).last_order_chat = Some(chat.clone());
            let via = m.from.as_ref().map(User::via).unwrap_or_else(|| format!("telegram:{}", order.sender_id));
            self.run_line(&chat, &order.body, &via, &order.sender_id.to_string()).await;
            return;
        }

        // An allowed user's group line that was not aimed at the bot. Not an
        // order on purpose, but silence teaches people the bot is broken in
        // groups: say how to reach it, once in a while.
        if inbound::is_unaddressed_order(&m, &cfg, bot_name) {
            let now = crate::auth::now();
            let due = {
                let mut sh = lock(&self.shared);
                let due = sh.last_hint.get(&chat).is_none_or(|t| now - t >= inbound::ADDRESSING_HINT_WINDOW);
                if due {
                    sh.last_hint.insert(chat.clone(), now);
                }
                due
            };
            if due {
                self.say(&chat, &inbound::addressing_hint(bot_name));
            }
            return;
        }

        if let Some(signal) = m.body().map(str::trim).filter(|t| !t.is_empty()) {
            self.deliver_signal(&m, signal, &cfg);
        }
    }

    /// A line through the command language, for this chat's conversation.
    pub(super) async fn run_line(self: &Arc<Self>, chat: &str, text: &str, via: &str, commander: &str) {
        let key = session::key(chat);
        let binding = ChatSession::load(&self.gw.store().state.chat_sessions, &key).binding();
        let mut context = json!({"desktop": false});
        if let Some(b) = binding {
            context["binding"] = b;
        }
        let params = json!({"text": text, "context": context, "_meta": {"via": via}});
        let outcome = match self.core_call("command.run", params, Duration::from_secs(120)).await {
            Ok(o) => o,
            Err(e) if core_unreachable(&e) => return self.say(chat, CORE_DOWN),
            Err(e) => return self.say(chat, &e.message),
        };
        if let Some(b) = outcome.get("binding") {
            let mut st = self.gw.store();
            let mut s = ChatSession::load(&st.state.chat_sessions, &key);
            if s.rebind(b, Some(commander)) {
                s.store(&mut st.state.chat_sessions);
                if let Err(e) = st.save_state() {
                    eprintln!("seahelm-gateway: telegram: save state: {e:#}");
                }
            }
        }
        let reply = outcome.get("text").and_then(Value::as_str).unwrap_or_default();
        let is_error = outcome.get("is_error").and_then(Value::as_bool).unwrap_or(false);
        // First Mate's answer comes back to the chat that spoke to it.
        let to_mate = if let Some(t) = outcome.get("first_mate").and_then(Value::as_str) {
            let _ = self.gw.core.call("autopilot.say", json!({"text": t, "_meta": {"via": via}})).await;
            true
        } else {
            !is_error && !inbound::is_slash_command(text) && reply.starts_with("→ First Mate")
        };
        if to_mate {
            let mut sh = lock(&self.shared);
            if !sh.first_mate_targets.contains(&key) {
                sh.first_mate_targets.push(key.clone());
            }
        }
        let buttons: Vec<Button> = {
            let mut reg = lock(&self.callbacks);
            outcome
                .get("buttons")
                .and_then(Value::as_array)
                .map(|bs| {
                    bs.iter()
                        .filter_map(|b| {
                            let label = b.get("label")?.as_str()?;
                            let line = b.get("line")?.as_str()?;
                            Some(Button { label: label.to_string(), token: reg.mint(Action::Command(line.to_string())) })
                        })
                        .collect()
                })
                .unwrap_or_default()
        };
        if !reply.is_empty() {
            self.say_with(chat, reply, buttons);
        }
    }

    /// `/start`. Which case applies turns on whether a code is armed, not on
    /// who sent it: pairing exists because the sender is not on the list yet.
    async fn handle_start(self: &Arc<Self>, payload: &str, m: &Message, cfg: &TelegramConfig) {
        // A channel post names no user, and an allowlist entry must.
        let Some(from) = &m.from else { return };
        let chat = m.chat.id.to_string();
        let allowed = cfg.allows(from.id, from.username.as_deref());
        let armed = {
            let mut p = lock(&self.pairing);
            match p.as_mut() {
                None => None,
                Some(_) if payload.is_empty() => Some(false),
                Some(s) => {
                    let ok = s.claim(payload, crate::auth::now());
                    if ok {
                        *p = None;
                    }
                    Some(ok)
                }
            }
        };
        match armed {
            Some(true) => {
                self.paired(from, &chat);
                self.say(
                    &chat,
                    "**Paired.** This chat can command the fleet now.\n\n`/status` lists what is running, `/help` lists the commands, and anything without a slash goes straight to the agent you are talking to.",
                );
                return;
            }
            Some(false) if !payload.is_empty() => {
                // A code is armed and this one failed: say so rather than
                // leave someone tapping Start again.
                self.say(&chat, "That pairing code has expired or was already used. Generate a new one in seahelm ▸ Settings ▸ Telegram.");
                return;
            }
            Some(false) if !allowed => {
                self.say(&chat, "Send me the 8-character pairing code shown in seahelm ▸ Settings ▸ Telegram to connect this chat.");
                return;
            }
            _ => {}
        }
        // A bare Start from someone trusted gets a greeting; from anyone else
        // silence: an unpaired bot must not confirm it drives a fleet.
        if allowed {
            self.say(&chat, "**seahelm** is connected. `/status` lists the fleet, `/help` lists the commands.");
        } else {
            eprintln!("seahelm-gateway: telegram: ignoring /start from unlisted user {}", from.id);
        }
    }

    /// The person who claimed the code is allowed from now on; their chat
    /// becomes the default chat when there is none.
    fn paired(&self, from: &User, chat: &str) {
        let id = from.id.to_string();
        {
            let mut st = self.gw.store();
            let tg = &mut st.config.telegram;
            if !tg.allowed_users.iter().any(|u| u.trim() == id) {
                tg.allowed_users.push(id.clone());
            }
            if tg.default_chat_id.as_deref().is_none_or(|c| c.trim().is_empty()) {
                tg.default_chat_id = Some(chat.to_string());
            }
            if let Err(e) = st.save_config() {
                eprintln!("seahelm-gateway: telegram: save config: {e:#}");
            }
        }
        eprintln!("seahelm-gateway: telegram: paired with {} in chat {chat}", from.id);
        self.gw.config_changed();
        self.gw.emit(json!({"type": "telegram.paired", "user_id": id, "display": from.display_name(), "chat_id": chat}));
    }

    /// Someone tapped a button. The tap is answered at once (Telegram spins
    /// the button until it is); what it meant comes back as a message, since
    /// "which option did I pick" is worth keeping in the chat.
    pub(super) async fn handle_callback(self: Arc<Self>, q: CallbackQuery) {
        let Some(live) = self.live() else { return };
        let cfg = self.config();
        if !cfg.allows(q.from.id, q.from.username.as_deref()) {
            let _ = live.bot.answer_callback_query(&q.id, Some("Not for you.")).await;
            return;
        }
        let _ = live.bot.answer_callback_query(&q.id, None).await;
        let (Some(token), Some(msg)) = (q.data.as_deref().filter(|t| !t.is_empty()), q.message.as_ref()) else { return };
        let chat = msg.chat.id.to_string();
        let message = msg.message_id;
        let via = q.from.via();
        lock(&self.shared).last_order_chat = Some(chat.clone());

        let action = lock(&self.callbacks).action(token).cloned();
        let card_id = match action {
            None => {
                self.say(&chat, "That card has already been answered — or it is from before seahelm last started.");
                return;
            }
            // A listing's shortcut (`/go #7`): not answering anything, so it
            // stays tappable.
            Some(Action::Command(line)) => {
                let me = self.clone();
                let commander = q.from.id.to_string();
                let c = chat.clone();
                self.in_chat(&chat, Box::pin(async move { me.run_line(&c, &line, &via, &commander).await }));
                return;
            }
            Some(Action::CardOption { card, index }) => {
                let found = self.gw.core.cards().borrow().iter().filter_map(notices::Card::from_json).find(|c| c.id == card);
                let Some(c) = found.filter(|c| index < c.labels.len()) else {
                    self.say(&chat, "That card is gone — the agent moved on.");
                    return;
                };
                let label = c.labels[index].clone();
                if let Err(e) = self.gw.core.call("cards.answer", json!({"id": card, "index": index, "_meta": {"via": via}})).await {
                    self.say(&chat, &format!("Couldn't answer that card: {}", e.message));
                    return;
                }
                // A multi-select tick leaves the question up; its ticks are
                // redrawn when the core sends the cards again.
                if c.multi_select && label != notices::DONE_LABEL {
                    self.book_card_message(&card, &chat, message);
                    return;
                }
                lock(&self.callbacks).retire(&card);
                self.say(&chat, &format!("Picked **{}**.", notices::picked_summary(&c, &label)));
                card
            }
            Some(Action::DismissCard { card }) => {
                let _ = self.gw.core.call("cards.dismiss", json!({"id": card, "_meta": {"via": via}})).await;
                self.say(&chat, "Left it. The agent is still waiting — answer it at the desk when you get there.");
                card
            }
        };
        // Dealt with: its buttons stop offering options in every chat that
        // was shown it, not only this one.
        self.book_card_message(&card_id, &chat, message);
        self.retire_card_buttons(&card_id);
    }

    fn book_card_message(&self, card: &str, chat: &str, message: i64) {
        let mut sh = lock(&self.shared);
        let refs = sh.card_buttons.entry(card.to_string()).or_default();
        if !refs.iter().any(|r| r.chat == chat && r.message == message) {
            refs.push(notices::Ref { chat: chat.to_string(), message, at: crate::auth::now() });
        }
    }

    /// Stop under the board in a private chat: Esc into the pane the chat is
    /// bound to, the one the board shows in full. A draft goes only to a
    /// private chat, whose id is the user's, so the chat is what is checked.
    pub(super) async fn handle_stop(self: Arc<Self>, stop: GenerationStopped) {
        let cfg = self.config();
        if !stop.chat.is_private() || !cfg.allows(stop.chat.id, stop.chat.username.as_deref()) {
            return;
        }
        let chat = stop.chat.id.to_string();
        let bound = ChatSession::load(&self.gw.store().state.chat_sessions, &session::key(&chat)).bound_pane().map(str::to_string);
        let meta = match &bound {
            Some(k) => self.pane_meta(k).await,
            None => None,
        };
        let (Some(key), Some(meta)) = (bound, meta) else {
            self.say(&chat, "Nothing to stop — this chat isn't talking to a running pane.");
            return;
        };
        let target = format!("#{} {}/{}", meta.handle, meta.project, meta.branch);
        let via = match stop.chat.username.as_deref().filter(|u| !u.is_empty()) {
            Some(u) => format!("telegram:@{u}"),
            None => format!("telegram:{chat}"),
        };
        let sent = self.gw.core.call("pane.send_keys", json!({"pane_id": key, "keys": ["escape"], "_meta": {"via": via}})).await;
        self.say(&chat, &if sent.is_ok() { format!("Stopped **{target}** (sent Esc).") } else { format!("Couldn't reach **{target}** to stop it.") });
    }

    /// Not an order, but maybe work: run it past the rules, and on a match
    /// type the prompt into the pane the rule names, after the coalescing
    /// window. Never replies: that would text an alerting service back. An
    /// allowed user's own words are never a signal.
    fn deliver_signal(self: &Arc<Self>, m: &Message, text: &str, cfg: &TelegramConfig) {
        let list = rules::parse_rules(&cfg.rules);
        if list.is_empty() || m.from.as_ref().is_some_and(|f| cfg.allows(f.id, f.username.as_deref())) {
            return;
        }
        let sender = inbound::signal_sender(m);
        let Some(hit) = rules::first_match(&list, &sender, text) else { return };
        eprintln!("seahelm-gateway: telegram: rule '{}' matched", hit.rule.name);
        let Some(key) = lock(&self.shared).coalescer.enqueue(&hit.prompt, &hit.rule.target) else { return };
        let me = self.clone();
        let via = format!("telegram:rule:{}", hit.rule.name);
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(rules::COALESCE_WINDOW_SECS)).await;
            let Some((prompt, target)) = lock(&me.shared).coalescer.flush(&key) else { return };
            let rows = me.refresh_panes().await;
            let Some(pane) = rules::resolve_pane(&target, &rows) else {
                eprintln!("seahelm-gateway: telegram: rule target {}={} resolved to no pane", target.kind, target.value);
                return;
            };
            if let Err(e) = me.gw.core.call("pane.run", json!({"pane_id": pane.session_key, "command": prompt, "_meta": {"via": via}})).await {
                eprintln!("seahelm-gateway: telegram: rule prompt to {} failed: {e}", pane.session_key);
            }
        });
    }

    /// The largest photo, or an image sent as a file, saved under
    /// `<gateway>/telegram/media/<id>/`. Failures are logged and skipped so
    /// a caption still gets through.
    async fn download_media(&self, m: &Message) -> Vec<String> {
        let Some(live) = self.live() else { return Vec::new() };
        let (file_id, doc_name) = if let Some(p) = m.photo.as_deref().and_then(inbound::preferred_photo) {
            (p.file_id.clone(), None)
        } else if let Some(d) = m.document.as_ref().filter(|d| inbound::is_image_document(d)) {
            (d.file_id.clone(), d.file_name.clone())
        } else {
            return Vec::new();
        };
        let result = async {
            let file = live.bot.get_file(&file_id).await.map_err(|e| e.to_string())?;
            let path = file.file_path.filter(|p| !p.is_empty()).ok_or("getFile returned no path")?;
            if file.file_size.is_some_and(|s| s as usize > super::api::MAX_FILE_BYTES) {
                return Err("file too large".to_string());
            }
            let data = live.bot.download_file(&path).await.map_err(|e| e.to_string())?;
            let dir = self.gw.store().dir().join("telegram").join("media").join(hex::encode(crate::auth::random_bytes(16)));
            tokio::fs::create_dir_all(&dir).await.map_err(|e| e.to_string())?;
            let out = dir.join(inbound::file_name(Some(&path), doc_name.as_deref()));
            tokio::fs::write(&out, data).await.map_err(|e| e.to_string())?;
            Ok::<_, String>(out.to_string_lossy().into_owned())
        }
        .await;
        match result {
            Ok(p) => vec![p],
            Err(e) => {
                eprintln!("seahelm-gateway: telegram: media download failed: {e}");
                Vec::new()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::RpcError;
    use crate::telegram::pairing;

    #[test]
    fn tells_a_down_core_from_a_refusal() {
        assert!(core_unreachable(&RpcError::new(-32000, "seahelm-core unavailable: connect")));
        assert!(!core_unreachable(&RpcError::new(-32602, "text required")));
    }

    #[test]
    fn pairing_codes_reach_start() {
        // What a deep link sends, in a group with the bot's suffix.
        let src = inbound::strip_bot_mention("/start@helm_bot ABCD2345", Some("helm_bot"));
        let payload = inbound::start_payload(&src).unwrap();
        let mut s = pairing::Session::with_code("ABCD2345".into(), 0.0);
        assert!(s.claim(&payload, 1.0));
    }
}
