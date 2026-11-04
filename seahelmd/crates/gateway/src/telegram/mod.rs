//! The Telegram adapter: seahelm's bot, as a client of seahelm-core
//! (docs/seahelm-gateway-plan.md, "Telegram in the gateway"). Ported from the
//! macOS app's `TelegramChannel` and the chat half of `MainWindowController`.
//!
//! - `api`: the Bot API over one pooled reqwest client; wire types.
//! - `format`: light markdown → Telegram HTML, 4096-character chunks.
//! - `inbound`: what a message is (order, `/start`, unaddressed group talk,
//!   rule input) and the media helpers.
//! - `session`: who each chat talks to (`state.chat_sessions`).
//! - `callbacks`: the tokens buttons carry.
//! - `pairing`: the one-time `/start <code>`.
//! - `rules`: the signal rules and their coalescer.
//! - `notices`: notice and card text, and the books that place buttons.
//! - `progress`: the live line in groups and the draft board in private chats.
//! - `outbox`, `handlers`, `fleet`: the async halves — sending in order,
//!   answering what comes in, following the core.
//!
//! Long polling, not a webhook: the gateway may have no public address, and
//! Telegram answers a held `getUpdates` the moment something arrives.

mod api;
mod callbacks;
mod fleet;
mod format;
mod handlers;
mod inbound;
mod notices;
mod outbox;
mod pairing;
mod progress;
mod rules;
mod session;

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, RwLock};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::sync::mpsc;

use crate::gateway::{Gateway, TelegramStatus};
use crate::rpc::{RpcError, RpcResult};
use crate::store::TelegramConfig;

type Job = Pin<Box<dyn Future<Output = ()> + Send>>;

static ADAPTER: OnceLock<Arc<Adapter>> = OnceLock::new();

/// The bot as connected now.
#[derive(Clone)]
struct Live {
    bot: api::Bot,
    username: Option<String>,
}

/// Small state the handlers share.
#[derive(Default)]
struct Shared {
    /// The chat the latest order came from: a fleet listener when no default
    /// chat is configured.
    last_order_chat: Option<String>,
    /// When each group was last told how to address the bot.
    last_hint: HashMap<String, f64>,
    /// Chats (`telegram:<id>`) waiting on First Mate's answer.
    first_mate_targets: Vec<String>,
    notice_book: notices::NoticeBook,
    seen_cards: notices::SeenCards,
    /// Where each card's buttons are drawn, to take them down when it goes.
    card_buttons: HashMap<String, Vec<notices::Ref>>,
    /// The labels a chat was last shown for a card, to redraw its ticks.
    card_labels: HashMap<String, Vec<String>>,
    packets: notices::PacketBook,
    coalescer: rules::Coalescer,
    /// The Mini App URL last put on the menu button.
    menu_url: Option<String>,
}

pub(crate) struct Adapter {
    gw: Arc<Gateway>,
    http: reqwest::Client,
    live: RwLock<Option<Live>>,
    outbox: mpsc::UnboundedSender<outbox::Op>,
    drafts: Mutex<HashMap<String, outbox::PendingDraft>>,
    callbacks: Mutex<callbacks::Registry>,
    pairing: Mutex<Option<pairing::Session>>,
    shared: Mutex<Shared>,
    progress: Mutex<progress::Progress>,
    panes: Mutex<fleet::PaneCache>,
    chats: Mutex<HashMap<String, mpsc::UnboundedSender<Job>>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Start the adapter: it watches `gw.config()` and (re)connects the bot.
pub fn spawn(gw: Arc<Gateway>) {
    let (tx, rx) = mpsc::unbounded_channel();
    let adapter = Arc::new(Adapter {
        gw,
        http: api::http_client(),
        live: RwLock::new(None),
        outbox: tx,
        drafts: Mutex::new(HashMap::new()),
        callbacks: Mutex::new(callbacks::Registry::default()),
        pairing: Mutex::new(None),
        shared: Mutex::new(Shared::default()),
        progress: Mutex::new(progress::Progress::default()),
        panes: Mutex::new(fleet::PaneCache::default()),
        chats: Mutex::new(HashMap::new()),
    });
    let _ = ADAPTER.set(adapter.clone());
    tokio::spawn(adapter.clone().run_outbox(rx));
    tokio::spawn(adapter.clone().run_connection());
    tokio::spawn(adapter.clone().follow_events());
    tokio::spawn(adapter.clone().follow_messages());
    tokio::spawn(adapter.follow_cards());
}

/// `gateway.sock` methods the adapter answers (`telegram.*`). Called on an
/// admin thread; None for a method that is not the adapter's.
pub fn admin(gw: &Arc<Gateway>, method: &str, params: &Value) -> Option<RpcResult> {
    if !method.starts_with("telegram.") {
        return None;
    }
    Some(match method {
        "telegram.validate_token" => {
            let token = params.get("bot_token").and_then(Value::as_str).unwrap_or_default().trim().to_string();
            if token.is_empty() {
                return Some(Ok(json!({"ok": false, "error": "No bot token given"})));
            }
            let http = ADAPTER.get().map(|a| a.http.clone()).unwrap_or_else(api::http_client);
            let bot = api::Bot::new(http, token);
            Ok(match gw.runtime.block_on(bot.get_me()) {
                Ok(me) => json!({"ok": true, "username": me.username}),
                Err(e) => json!({"ok": false, "error": e.to_string()}),
            })
        }
        "telegram.pair.begin" => {
            let Some(adapter) = ADAPTER.get() else { return Some(Err(RpcError::new(-32000, "the Telegram adapter is not running"))) };
            // A token set a moment ago is still connecting: give it a little.
            let mut username = adapter.username();
            for _ in 0..50 {
                if username.is_some() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(200));
                username = adapter.username();
            }
            let Some(username) = username else {
                return Some(Err(RpcError::new(-32000, "The Telegram bot is not connected: set a bot token and turn Telegram on first.")));
            };
            let session = pairing::Session::new(crate::auth::now());
            *lock(&adapter.pairing) = Some(session.clone());
            Ok(json!({"code": session.code, "deep_link": pairing::deep_link(&username, &session.code), "expires_at": session.expires_at}))
        }
        "telegram.pair.cancel" => {
            if let Some(a) = ADAPTER.get() {
                *lock(&a.pairing) = None;
            }
            Ok(json!({"ok": true}))
        }
        other => Err(RpcError::not_found(other)),
    })
}

/// Where unbound fleet notices go: the configured chat, else the first
/// numeric allowed user (a private chat's id is the user's).
fn default_chat(cfg: &TelegramConfig) -> Option<String> {
    if let Some(c) = cfg.default_chat_id.as_deref().map(str::trim).filter(|c| !c.is_empty()) {
        return Some(c.to_string());
    }
    cfg.allowed_users.iter().map(|u| u.trim().trim_start_matches('@').to_string()).find(|u| is_numeric_id(u))
}

fn is_numeric_id(s: &str) -> bool {
    let digits = s.strip_prefix('-').unwrap_or(s);
    !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit())
}

/// What the command list (`setMyCommands`) offers: the core's verbs.
const BOT_COMMANDS: &[(&str, &str)] = &[
    ("go", "Talk to a pane, a worktree's pane, or First Mate from now on"),
    ("new", "Start a worktree with an agent on the task, and talk to it"),
    ("status", "The fleet, with handles"),
    ("show", "What a pane is doing"),
    ("help", "This list; with a command, its details"),
];

const MAX_BACKOFF: u64 = 30;

impl Adapter {
    fn config(&self) -> TelegramConfig {
        self.gw.store().config.telegram.clone()
    }

    fn live(&self) -> Option<Live> {
        self.live.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn username(&self) -> Option<String> {
        self.live().and_then(|l| l.username)
    }

    fn set_status(&self, f: impl FnOnce(&mut TelegramStatus)) {
        let changed = {
            let mut s = lock(&self.gw.telegram_status);
            let before = s.clone();
            f(&mut s);
            *s != before
        };
        if changed {
            self.gw.status_changed();
        }
    }

    /// Run `job` after every earlier job for the same chat: orders from one
    /// chat stay in order, and a slow `/new` holds up no other chat.
    fn in_chat(&self, chat: &str, job: Job) {
        let mut chats = lock(&self.chats);
        let job = match chats.get(chat) {
            Some(tx) => match tx.send(job) {
                Ok(()) => return,
                Err(e) => e.0,
            },
            None => job,
        };
        let (tx, mut rx) = mpsc::unbounded_channel::<Job>();
        let _ = tx.send(job);
        chats.insert(chat.to_string(), tx);
        tokio::spawn(async move {
            while let Some(j) = rx.recv().await {
                j.await;
            }
        });
    }

    /// A core call with its own timeout (`command.run` may wait on
    /// `git worktree add`).
    async fn core_call(&self, method: &str, params: Value, timeout: Duration) -> RpcResult {
        let core = self.gw.core.clone();
        let method = method.to_string();
        tokio::task::spawn_blocking(move || core.call_blocking(&method, params, timeout)).await.unwrap_or_else(|e| Err(RpcError::internal(e.to_string())))
    }

    /// The chat can no longer be written to: close its binding, or every
    /// notice for its pane fails the same way for ever.
    fn chat_gone(&self, chat: &str) {
        let key = session::key(chat);
        let mut st = self.gw.store();
        let mut s = session::ChatSession::load(&st.state.chat_sessions, &key);
        if !st.state.chat_sessions.contains_key(&key) || s.closed {
            return;
        }
        s.closed = true;
        s.store(&mut st.state.chat_sessions);
        if let Err(e) = st.save_state() {
            eprintln!("seahelm-gateway: telegram: save state: {e:#}");
        }
        eprintln!("seahelm-gateway: telegram: {key} closed, the chat no longer accepts messages");
    }

    // MARK: connection

    /// Follow the settings: connected while Telegram is on and a token is
    /// set; a new token reconnects, and a changed Mini App URL moves the
    /// menu button without one.
    async fn run_connection(self: Arc<Self>) {
        let mut rx = self.gw.config();
        loop {
            let (cfg, token) = rx.borrow_and_update().clone();
            let Some(token) = token.filter(|_| cfg.telegram.enabled) else {
                self.set_status(|s| *s = TelegramStatus::default());
                if rx.changed().await.is_err() {
                    return;
                }
                continue;
            };
            let session = tokio::spawn(self.clone().run_bot(token.clone()));
            loop {
                if rx.changed().await.is_err() {
                    session.abort();
                    return;
                }
                let (c, t) = rx.borrow_and_update().clone();
                if t.filter(|_| c.telegram.enabled).as_deref() != Some(token.as_str()) {
                    break;
                }
                self.clone().apply_menu_button(&c.telegram).await;
            }
            session.abort();
            *self.live.write().unwrap_or_else(|e| e.into_inner()) = None;
            self.set_status(|s| *s = TelegramStatus::default());
            eprintln!("seahelm-gateway: telegram: disconnected");
        }
    }

    /// Point the menu button at the Mini App. Put back to the default only
    /// when a URL this gateway set was cleared: a button somebody set by hand
    /// is left alone.
    async fn apply_menu_button(self: Arc<Self>, cfg: &TelegramConfig) {
        let want = cfg.mini_app_url();
        let had = lock(&self.shared).menu_url.clone();
        let Some(live) = self.live() else { return };
        if want == had {
            return;
        }
        let result = live.bot.set_menu_button(want.as_deref()).await;
        match result {
            Ok(()) => lock(&self.shared).menu_url = want,
            Err(e) => eprintln!("seahelm-gateway: telegram: could not set the menu button: {e}"),
        }
    }

    /// Runs `work` until it succeeds, backing off. None on an error retrying
    /// cannot fix (a rejected token), which becomes the status's error.
    async fn retrying<T, F, Fut>(&self, label: &str, mut work: F) -> Option<T>
    where
        F: FnMut() -> Fut,
        Fut: Future<Output = Result<T, api::ApiError>>,
    {
        let mut backoff = 1;
        loop {
            match work().await {
                Ok(v) => return Some(v),
                Err(e) if e.is_fatal() => {
                    eprintln!("seahelm-gateway: telegram: {e}");
                    self.set_status(|s| {
                        s.connected = false;
                        s.error = Some(e.to_string());
                    });
                    return None;
                }
                Err(e) => {
                    eprintln!("seahelm-gateway: telegram: {label} failed: {e}; retrying in {backoff}s");
                    self.set_status(|s| {
                        s.connected = false;
                        s.error = Some(e.to_string());
                    });
                    tokio::time::sleep(Duration::from_secs(backoff)).await;
                    backoff = (backoff * 2).min(MAX_BACKOFF);
                }
            }
        }
    }

    async fn run_bot(self: Arc<Self>, token: String) {
        let bot = api::Bot::new(self.http.clone(), token);
        let Some(me) = self.retrying("getMe", || bot.get_me()).await else { return };
        let username = me.username.clone().filter(|u| !u.is_empty());
        eprintln!("seahelm-gateway: telegram: connected as @{}", username.clone().unwrap_or_else(|| me.id.to_string()));
        *self.live.write().unwrap_or_else(|e| e.into_inner()) = Some(Live { bot: bot.clone(), username: username.clone() });
        self.set_status(|s| s.bot_username = username.clone());
        // Best effort, every connect: typing `/` lists the verbs, and a Mini
        // App URL changed while disconnected is on the button.
        if let Err(e) = bot.set_my_commands(BOT_COMMANDS).await {
            eprintln!("seahelm-gateway: telegram: setMyCommands failed: {e}");
        }
        lock(&self.shared).menu_url = None;
        self.clone().apply_menu_button(&self.config()).await;

        // Drain what Telegram queued. Anything older than the backfill window
        // is acknowledged and dropped (turning the bot on must not replay a
        // day of messages as orders); recent messages are delivered, covering
        // the gap between a text and the gateway starting. The offset moves
        // page by page so a failure resumes after what was handled.
        let mut offset: Option<i64> = None;
        let cutoff = crate::auth::now() - self.config().backfill_seconds;
        loop {
            let Some(updates) = self.retrying("backlog", || bot.get_updates(offset, 0)).await else { return };
            let Some(last) = updates.last().map(|u| u.update_id) else { break };
            for u in updates {
                if let Some(m) = u.payload().filter(|m| m.date >= cutoff) {
                    self.dispatch_message(m.clone());
                }
            }
            offset = Some(last + 1);
        }
        self.set_status(|s| {
            s.connected = true;
            s.error = None;
        });

        loop {
            let Some(updates) = self.retrying("poll", || bot.get_updates(offset, api::LONG_POLL_SECONDS)).await else { return };
            self.set_status(|s| {
                s.connected = true;
                s.error = None;
            });
            for u in updates {
                offset = Some(offset.unwrap_or(0).max(u.update_id + 1));
                if let Some(m) = u.payload() {
                    self.dispatch_message(m.clone());
                } else if let Some(q) = u.callback_query {
                    tokio::spawn(self.clone().handle_callback(q));
                } else if let Some(stop) = u.stopped_message_generation {
                    tokio::spawn(self.clone().handle_stop(stop));
                }
            }
        }
    }

    fn dispatch_message(self: &Arc<Self>, m: api::Message) {
        let chat = m.chat.id.to_string();
        self.in_chat(&chat, Box::pin(self.clone().handle_message(m)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_chat_falls_back_to_a_numeric_user() {
        let mut c = TelegramConfig { allowed_users: vec!["@me".into(), "  42 ".into()], ..TelegramConfig::default() };
        assert_eq!(default_chat(&c).as_deref(), Some("42"));
        c.default_chat_id = Some("-1001".into());
        assert_eq!(default_chat(&c).as_deref(), Some("-1001"));
        c.default_chat_id = Some(" ".into());
        c.allowed_users = vec!["@me".into()];
        assert_eq!(default_chat(&c), None);
    }

    #[test]
    fn the_command_list_fits_telegram() {
        for (c, d) in BOT_COMMANDS {
            assert!(c.len() <= 32 && c.chars().all(|ch| ch.is_ascii_lowercase()));
            assert!(d.len() <= 256);
        }
    }
}
