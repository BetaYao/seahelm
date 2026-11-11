//! One seahelm-web connection: auth, then the fleet as the core reports it,
//! the page's requests, and the terminals it opened
//! (docs/seahelm-gateway-plan.md, "Web wire protocol").

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::ws::{Message, WebSocket};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Map, Value};
use tokio::sync::{broadcast, mpsc};

use super::frames::{self, VtEvent};
use super::vt::VtStreams;
use super::FIRST_MATE;
use crate::auth;
use crate::gateway::{Gateway, Kick};
use crate::rpc::{RpcError, RpcResult};

/// What the upgrade request said about the page.
#[derive(Debug, Clone, Default)]
pub struct Meta {
    pub host: Option<String>,
    pub client_ip: String,
    pub user_agent: String,
}

const PING_EVERY: Duration = Duration::from_secs(30);
/// Two and a half missed pongs.
const SILENCE_LIMIT: Duration = Duration::from_secs(75);
/// Refused on a share link: not about the shared pane.
const SHARE_FORBIDDEN: i64 = -32003;

/// Who is on the other end, once signed in.
enum Who {
    Nobody,
    Device { id: String, label: String },
    Share(Shared),
}

/// A share-link connection: the one pane it may see and act on.
struct Shared {
    key: String,
    link_id: String,
    /// The pane's client id (an alias), learnt from `pane.list`.
    pane_id: Option<String>,
    sender: String,
}

impl Shared {
    fn names(&self, r: &str) -> bool {
        !r.is_empty() && (r == self.key || self.pane_id.as_deref() == Some(r))
    }
}

struct Session {
    gw: Arc<Gateway>,
    meta: Meta,
    who: Who,
    vt_binary: bool,
    vt_deflate: bool,
    keys_binary: bool,
    vt: VtStreams,
    /// agent_type last told per pane, so `pane.updated` goes out only when
    /// it changes (an agent starting, or exiting to the shell).
    sent_agent: HashMap<String, String>,
    /// Timeline rows at or below this were in the auth replay.
    message_floor: u64,
    out: mpsc::Sender<Message>,
}

pub async fn run(gw: Arc<Gateway>, socket: WebSocket, meta: Meta) {
    let (mut sink, mut stream) = socket.split();
    let (out_tx, mut out_rx) = mpsc::channel::<Message>(256);
    let (vt_tx, mut vt_rx) = mpsc::channel::<VtEvent>(64);
    let mut events = gw.core.events();
    let mut messages = gw.core.messages();
    let mut cards = gw.core.cards();
    let mut first_mate = gw.core.first_mate();
    let mut kick = gw.kick.subscribe();
    let mut s = Session {
        gw: gw.clone(),
        meta,
        who: Who::Nobody,
        vt_binary: false,
        vt_deflate: false,
        keys_binary: false,
        vt: VtStreams::new(vt_tx),
        sent_agent: HashMap::new(),
        message_floor: 0,
        out: out_tx,
    };
    let mut ticker = tokio::time::interval(PING_EVERY);
    ticker.tick().await;
    let mut last_heard = Instant::now();
    adjust_clients(&gw, 1);

    loop {
        let authed = !matches!(s.who, Who::Nobody);
        let outbound: Vec<Message> = tokio::select! {
            incoming = stream.next() => {
                last_heard = Instant::now();
                match incoming {
                    Some(Ok(Message::Text(text))) => s.handle_text(text.as_str()).await,
                    Some(Ok(Message::Binary(bytes))) => { s.handle_binary(&bytes); Vec::new() }
                    Some(Ok(Message::Ping(_) | Message::Pong(_))) => Vec::new(),
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                }
            }
            Some(m) = out_rx.recv() => vec![m],
            Some(e) = vt_rx.recv() => {
                if authed && s.vt.is_current(&e) { vec![s.encode_vt(&e)] } else { Vec::new() }
            }
            ev = events.recv() => match ev {
                Ok(ev) if authed => s.core_event(&ev),
                Ok(_) => Vec::new(),
                // Missed events: the page's picture is stale. A reconnect
                // rebuilds it from scratch.
                Err(broadcast::error::RecvError::Lagged(_)) if authed => break,
                Err(broadcast::error::RecvError::Lagged(_)) => Vec::new(),
                Err(broadcast::error::RecvError::Closed) => break,
            },
            row = messages.recv() => match row {
                Ok(row) if authed => s.message(&row),
                Ok(_) => Vec::new(),
                Err(broadcast::error::RecvError::Lagged(_)) if authed => break,
                Err(broadcast::error::RecvError::Lagged(_)) => Vec::new(),
                Err(broadcast::error::RecvError::Closed) => break,
            },
            changed = cards.changed() => {
                if changed.is_err() { break; }
                let list = cards.borrow_and_update().clone();
                if authed { vec![s.cards_notify(&list)] } else { Vec::new() }
            }
            changed = first_mate.changed() => {
                if changed.is_err() { break; }
                let state = first_mate.borrow_and_update().clone();
                match (authed, &s.who, state) {
                    (true, Who::Device { .. }, Some(st)) => vec![notify("autopilot.state", (*st).clone())],
                    _ => Vec::new(),
                }
            }
            k = kick.recv() => match k {
                Ok(k) if s.kicked(&k) => break,
                _ => Vec::new(),
            },
            _ = ticker.tick() => {
                if last_heard.elapsed() > SILENCE_LIMIT { break; }
                s.vt.reap();
                if s.share_dead() { break; }
                vec![Message::Ping(Vec::new().into())]
            }
        };
        let mut failed = false;
        for m in outbound {
            if sink.send(m).await.is_err() {
                failed = true;
                break;
            }
        }
        if failed {
            break;
        }
    }
    s.vt.close_all();
    if let Who::Device { id, .. } = &s.who {
        let mut c = gw.connected_devices.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(n) = c.get_mut(id) {
            *n = n.saturating_sub(1);
        }
    }
    adjust_clients(&gw, -1);
    let _ = sink.close().await;
}

fn adjust_clients(gw: &Gateway, by: isize) {
    let mut st = gw.web_status.lock().unwrap_or_else(|e| e.into_inner());
    st.clients = st.clients.saturating_add_signed(by);
}

fn notify(method: &str, params: Value) -> Message {
    text(&json!({"type": "notify", "method": method, "params": params}))
}

fn text(v: &Value) -> Message {
    Message::Text(v.to_string().into())
}

fn response(id: &Value, result: RpcResult) -> Message {
    match result {
        Ok(v) => text(&json!({"id": id, "result": v})),
        Err(e) => text(&json!({"id": id, "error": {"code": e.code, "message": e.message}})),
    }
}

fn str_of<'a>(p: &'a Value, k: &str) -> Option<&'a str> {
    p.get(k).and_then(Value::as_str).filter(|s| !s.is_empty())
}

/// What a request names a pane by.
fn pane_ref(p: &Value) -> Option<String> {
    str_of(p, "pane_session_key").or_else(|| str_of(p, "pane_id")).map(str::to_string)
}

/// Methods a paired page may not call: the core's client-side plumbing.
const NOT_FOR_PAGES: &[&str] = &[
    "pane.register", "pane.unregister", "pane.sync", "worktrees.set", "layouts.set", "client.visible", "events.subscribe",
    "message.subscribe", "hook", "suggest", "cards.raise", "cards.clear", "autopilot.propose", "agent.forget",
];

impl Session {
    fn via(&self) -> String {
        match &self.who {
            Who::Device { label, .. } => format!("web:{label}"),
            Who::Share(s) => format!("share:{}", s.sender),
            Who::Nobody => "web".into(),
        }
    }

    /// A core call carrying who it is for.
    async fn core(&self, method: &str, mut params: Value) -> RpcResult {
        if let Some(o) = params.as_object_mut() {
            o.insert("_meta".into(), json!({"via": self.via()}));
        }
        self.gw.core.call(method, params).await
    }

    fn shared(&self) -> Option<&Shared> {
        match &self.who {
            Who::Share(s) => Some(s),
            _ => None,
        }
    }

    /// True for a paired page; for a share page only when a ref names its pane.
    fn in_scope(&self, refs: &[Option<&str>]) -> bool {
        match self.shared() {
            None => true,
            Some(s) => refs.iter().flatten().any(|r| s.names(r)),
        }
    }

    fn kicked(&self, k: &Kick) -> bool {
        match (k, &self.who) {
            (Kick::All, Who::Nobody) => false,
            (Kick::All, _) => true,
            (Kick::Device(d), Who::Device { id, .. }) => d == id,
            (Kick::Share(l), Who::Share(s)) => *l == s.link_id,
            _ => false,
        }
    }

    /// A share page whose link was revoked or ran out.
    fn share_dead(&self) -> bool {
        let Some(s) = self.shared() else { return false };
        let st = self.gw.store();
        !st.state.share_links.iter().any(|l| l.id == s.link_id && l.is_live(auth::now()))
    }

    fn encode_vt(&self, e: &VtEvent) -> Message {
        if self.vt_binary {
            if let Some(f) = frames::encode_vt(e, self.vt_deflate) {
                return Message::Binary(f.into());
            }
        }
        text(&frames::legacy_notify(e))
    }

    fn handle_binary(&mut self, bytes: &[u8]) {
        if matches!(self.who, Who::Nobody) || !self.keys_binary {
            return;
        }
        if let Some((key, utf8)) = frames::decode_keys(bytes) {
            if self.vt.is_open(&key) {
                self.vt.send(&key, utf8);
            }
        }
    }

    async fn handle_text(&mut self, raw: &str) -> Vec<Message> {
        let Ok(req) = serde_json::from_str::<Value>(raw) else {
            return vec![response(&json!(""), Err(RpcError::new(-32700, "parse error")))];
        };
        let Some(method) = req.get("method").and_then(Value::as_str).map(str::to_string) else {
            return vec![response(&json!(""), Err(RpcError::new(-32700, "parse error")))];
        };
        let id = match req.get("id") {
            Some(Value::String(s)) => json!(s),
            Some(Value::Null) | None => json!(""),
            Some(other) => json!(other.to_string()),
        };
        let params = req.get("params").cloned().filter(Value::is_object).unwrap_or_else(|| json!({}));
        if matches!(self.who, Who::Nobody) {
            if method != "auth" {
                return vec![response(&id, Err(RpcError::new(-32001, "unauthorized")))];
            }
            return self.auth(&id, &params).await;
        }
        if let Some(refused) = self.share_gate(&method, &params) {
            return vec![response(&id, Err(refused))];
        }
        match self.request(&id, &method, params).await {
            Some(r) => vec![response(&id, r)],
            None => Vec::new(),
        }
    }

    /// A share page's request that may not go through.
    fn share_gate(&self, method: &str, p: &Value) -> Option<RpcError> {
        let s = self.shared()?;
        let refuse = || Some(RpcError::new(SHARE_FORBIDDEN, "not allowed on a shared pane"));
        match method {
            "ping" | "session.snapshot" | "pane.list" | "fleet.groups" => None,
            "cards.answer" | "cards.dismiss" => {
                let id = str_of(p, "id")?;
                let cards = self.gw.core.cards().borrow().clone();
                let mine = cards.iter().any(|c| c["id"].as_str() == Some(id) && c["pane_session_key"].as_str().is_some_and(|k| s.names(k)));
                if mine {
                    None
                } else {
                    refuse()
                }
            }
            // A guest does not get to reshape the owner's terminal.
            "pane.vt_size" => refuse(),
            "pane.vt_open" | "pane.vt_close" | "pane.vt_keepalive" | "pane.send_keys" | "pane.send_text" | "pane.seen" | "message.history" => {
                let refs: Vec<&str> = ["pane_session_key", "pane_id"].iter().filter_map(|k| str_of(p, k)).collect();
                if !refs.is_empty() && refs.iter().all(|r| s.names(r)) {
                    None
                } else {
                    refuse()
                }
            }
            _ => refuse(),
        }
    }

    /// One request after auth. None: answered later by a spawned task.
    async fn request(&mut self, id: &Value, method: &str, mut p: Value) -> Option<RpcResult> {
        Some(match method {
            "ping" => Ok(json!({"pong": true})),
            "session.snapshot" | "pane.list" => self.panes().await.map(|panes| json!({"panes": panes})),
            "fleet.groups" => {
                let mode = str_of(&p, "mode").unwrap_or("repository").to_string();
                let (wts, panes) = tokio::join!(self.gw.core.call("worktree.list", json!({})), self.gw.core.call("pane.list", json!({})));
                let wts = wts.map(|r| r["worktrees"].as_array().cloned().unwrap_or_default());
                let panes = panes.map(|r| r["panes"].as_array().cloned().unwrap_or_default());
                match (wts, panes) {
                    (Ok(mut wts), Ok(panes)) => {
                        if let Some(s) = self.shared() {
                            let mine: Vec<&str> =
                                panes.iter().filter(|p| p["pane_session_key"].as_str().is_some_and(|k| s.names(k))).filter_map(|p| p["worktree_path"].as_str()).collect();
                            wts.retain(|w| w["worktree_path"].as_str().is_some_and(|w| mine.contains(&w)));
                        }
                        Ok(super::fleet::groups(&mode, &wts, &panes, auth::now()))
                    }
                    (Err(e), _) | (_, Err(e)) => Err(e),
                }
            }
            "pane.vt_open" => {
                let key = pane_ref(&p).unwrap_or_default();
                let vt = &mut self.vt;
                Ok(tokio::task::block_in_place(|| vt.open(&key)))
            }
            "pane.vt_size" => {
                let key = pane_ref(&p).unwrap_or_default();
                let n = |k: &str| p.get(k).and_then(Value::as_u64).unwrap_or(0).min(u16::MAX as u64) as u16;
                let (cols, rows) = (n("cols"), n("rows"));
                let take_over = p.get("take_over").and_then(Value::as_bool).unwrap_or(false);
                let vt = &mut self.vt;
                Ok(tokio::task::block_in_place(|| vt.resize(&key, cols, rows, take_over)))
            }
            "pane.vt_close" => {
                self.vt.close(&pane_ref(&p).unwrap_or_default());
                Ok(json!({"ok": true}))
            }
            "pane.vt_keepalive" => {
                self.vt.keepalive(&pane_ref(&p).unwrap_or_default());
                Ok(json!({"ok": true}))
            }
            "pane.send_keys" => {
                let key = pane_ref(&p).unwrap_or_default();
                let bytes = str_of(&p, "b64")
                    .and_then(|b| base64::Engine::decode(&base64::engine::general_purpose::STANDARD, b).ok())
                    .or_else(|| p.get("text").and_then(Value::as_str).map(|t| t.as_bytes().to_vec()));
                match bytes {
                    Some(bytes) if self.vt.is_open(&key) => Ok(json!({"sent": self.vt.send(&key, bytes)})),
                    _ => {
                        p["pane_id"] = json!(key);
                        self.core("pane.send_keys", p).await
                    }
                }
            }
            "pane.send_text" => {
                if let Some(k) = pane_ref(&p) {
                    p["pane_id"] = json!(k);
                }
                // A message from a share link carries who said it; keystrokes cannot.
                if let Some(s) = self.shared() {
                    if p["enter"].as_bool() == Some(true) {
                        let said = str_of(&p, "text").or_else(|| str_of(&p, "command")).map(str::to_string);
                        if let Some(t) = said {
                            p["text"] = json!(format!("[from {}] {t}", s.sender));
                            if let Some(o) = p.as_object_mut() {
                                o.remove("command");
                            }
                        }
                    }
                }
                self.core("pane.send_text", p).await
            }
            // Seconds of git, or a session to start: answered when done.
            "worktree.create" | "pane.new" | "worktree.delete" => {
                let gw = self.gw.clone();
                let out = self.out.clone();
                let id = id.clone();
                let method = method.to_string();
                if let Some(o) = p.as_object_mut() {
                    o.insert("_meta".into(), json!({"via": self.via()}));
                }
                tokio::spawn(async move {
                    let r = gw.core.call(&method, p).await;
                    let _ = out.send(response(&id, r)).await;
                });
                return None;
            }
            m if NOT_FOR_PAGES.contains(&m) => Err(RpcError::not_found(m)),
            m => self.core(m, p).await,
        })
    }

    /// `pane.list` as this page may see it: First Mate's pane left out (it
    /// comes with `autopilot.state`), a share page held to its pane.
    async fn panes(&mut self) -> Result<Vec<Value>, RpcError> {
        let r = self.gw.core.call("pane.list", json!({})).await?;
        let mut panes: Vec<Value> = r["panes"].as_array().cloned().unwrap_or_default();
        panes.retain(|p| p["pane_session_key"].as_str() != Some(FIRST_MATE));
        if let Who::Share(s) = &mut self.who {
            panes.retain(|p| p["pane_session_key"].as_str() == Some(s.key.as_str()));
            if let Some(alias) = panes.first().and_then(|p| p["pane_id"].as_str()) {
                s.pane_id = Some(alias.to_string());
            }
        }
        self.sent_agent = panes
            .iter()
            .filter_map(|p| Some((p["pane_session_key"].as_str()?.to_string(), p["agent_type"].as_str().unwrap_or("").to_string())))
            .collect();
        Ok(panes)
    }

    fn cards_notify(&self, list: &[Value]) -> Message {
        let cards: Vec<&Value> = list.iter().filter(|c| self.in_scope(&[c["pane_session_key"].as_str(), c["pane_id"].as_str()])).collect();
        notify("cards", json!({"cards": cards}))
    }

    fn message(&self, row: &Value) -> Vec<Message> {
        if row["seq"].as_u64().is_some_and(|s| s <= self.message_floor) {
            return Vec::new();
        }
        if !self.in_scope(&[row["pane_session_key"].as_str(), row["pane_id"].as_str()]) {
            return Vec::new();
        }
        vec![notify("pane.message", row.clone())]
    }

    /// A core event, in the page's words.
    fn core_event(&mut self, ev: &Value) -> Vec<Message> {
        let ty = ev["type"].as_str().unwrap_or("");
        let key = ev["pane_session_key"].as_str().unwrap_or("");
        if key == FIRST_MATE || !self.in_scope(&[Some(key), ev["pane_id"].as_str()]) {
            return Vec::new();
        }
        let pick = |keys: &[&str]| {
            let mut m = Map::new();
            for k in keys {
                if let Some(v) = ev.get(*k) {
                    m.insert((*k).into(), v.clone());
                }
            }
            Value::Object(m)
        };
        const STATUS_KEYS: &[&str] = &["pane_id", "pane_session_key", "status", "old_status", "agent_type", "worktree_path", "last_message"];
        match ty {
            "pane.status_changed" => {
                if let Some(a) = ev["agent_type"].as_str() {
                    self.sent_agent.insert(key.into(), a.into());
                }
                vec![notify("pane.status", pick(STATUS_KEYS))]
            }
            "pane.updated" => {
                let Some(a) = ev["agent_type"].as_str() else { return Vec::new() };
                if self.sent_agent.get(key).map(String::as_str) == Some(a) {
                    return Vec::new();
                }
                self.sent_agent.insert(key.into(), a.into());
                vec![notify("pane.status", pick(STATUS_KEYS))]
            }
            "pane.renamed" => vec![notify("pane.status", pick(&["pane_id", "pane_session_key", "worktree_path", "custom_title", "display_title"]))],
            "pane.unseen_changed" => vec![notify("pane.status", pick(&["pane_id", "pane_session_key", "worktree_path", "unseen"]))],
            "pane.closed" => {
                self.sent_agent.remove(key);
                vec![notify("pane.closed", pick(&["pane_id", "pane_session_key", "worktree_path"]))]
            }
            "pane.registered" => {
                let pane = ev.get("pane").cloned().unwrap_or_else(|| ev.clone());
                if let Some(a) = pane["agent_type"].as_str() {
                    self.sent_agent.insert(key.into(), a.into());
                }
                vec![notify("pane.added", pane)]
            }
            _ => Vec::new(),
        }
    }

    // MARK: auth

    async fn auth(&mut self, id: &Value, p: &Value) -> Vec<Message> {
        let s = |k: &str| str_of(p, k).unwrap_or("").to_string();
        let (token, mac, code, init_data, share) = (s("token"), s("mac_id"), s("code"), s("telegram_init_data"), s("share"));
        let telegram_only = {
            let st = self.gw.store();
            match (st.telegram_host(), self.meta.host.as_deref()) {
                (Some(want), Some(host)) => want == host,
                _ => false,
            }
        };

        let outcome: Result<(Who, Option<String>), &'static str> = if !share.is_empty() {
            let pane = s("pane");
            let check = auth::check_share(&self.gw.store().state.share_links, &share, &pane, auth::now());
            match check {
                auth::ShareCheck::Valid { id: link_id, recipient } => match recipient.or_else(|| auth::sender_name(&s("name"))) {
                    Some(sender) => Ok((Who::Share(Shared { key: pane, link_id, pane_id: None, sender }), None)),
                    None => Err("name_required"),
                },
                auth::ShareCheck::Expired => Err("expired"),
                auth::ShareCheck::Invalid => Err("invalid"),
            }
        } else if !token.is_empty() {
            self.sign_in_with_token(&mac, &token)
        } else if !init_data.is_empty() {
            let (token, cfg) = {
                let st = self.gw.store();
                (st.bot_token(), st.config.telegram.clone())
            };
            match auth::telegram_sign_in(&init_data, token.as_deref(), &cfg) {
                Some(user) => {
                    eprintln!("seahelm-gateway: Telegram sign-in accepted for {}", user.id);
                    let label = user.username.map(|u| format!("Telegram @{u}")).unwrap_or_else(|| format!("Telegram {}", user.id));
                    Ok(self.new_device(&label, "telegram"))
                }
                None => {
                    eprintln!("seahelm-gateway: Telegram sign-in refused");
                    Err("invalid")
                }
            }
        } else if !code.is_empty() {
            if telegram_only {
                eprintln!("seahelm-gateway: pairing code refused on the Telegram host");
                Err("invalid")
            } else {
                let ip = self.meta.client_ip.clone();
                if !self.gw.limiter.lock().unwrap_or_else(|e| e.into_inner()).allow(&ip) {
                    return vec![response(id, Err(RpcError::new(-32029, "rate_limited")))];
                }
                let ok = auth::verify_code(self.gw.store().secrets.pair_code.as_deref(), &code);
                let mut limiter = self.gw.limiter.lock().unwrap_or_else(|e| e.into_inner());
                if ok {
                    limiter.success(&ip);
                    drop(limiter);
                    let label = device_label(&self.meta.user_agent);
                    Ok(self.new_device(&label, "code"))
                } else {
                    limiter.failure(&ip);
                    Err("invalid")
                }
            }
        } else {
            Err("invalid")
        };

        let (who, token) = match outcome {
            Ok(x) => x,
            Err(reason) => {
                let reply = json!({"ok": false, "reason": reason, "vt_binary": false, "vt_deflate": false, "keys_binary": false});
                return vec![response(id, Ok(reply))];
            }
        };
        if let Who::Device { id: dev, .. } = &who {
            *self.gw.connected_devices.lock().unwrap_or_else(|e| e.into_inner()).entry(dev.clone()).or_default() += 1;
        }
        self.who = who;
        self.vt_binary = p["vt_binary"].as_bool().unwrap_or(false);
        self.vt_deflate = self.vt_binary && p["vt_deflate"].as_bool().unwrap_or(false);
        self.keys_binary = p["keys_binary"].as_bool().unwrap_or(false);

        let mut result = json!({
            "ok": true, "vt_binary": self.vt_binary, "vt_deflate": self.vt_deflate, "keys_binary": self.keys_binary,
            "mac_id": self.gw.store().secrets.mac_id,
        });
        if let Some(t) = token {
            result["token"] = json!(t);
        }
        if let Who::Share(s) = &self.who {
            result["share"] = json!(s.key);
            result["share_sender"] = json!(s.sender);
        }

        // The timeline: what came after the page's `since_seq` when the core
        // still has it, else the whole ring.
        let since = p["since_seq"].as_u64().filter(|n| *n > 0);
        let mut rows: Vec<Value> = Vec::new();
        let mut delta = false;
        if let Some(after) = since {
            if let Ok(r) = self.gw.core.call("message.replay", json!({"after_seq": after})).await {
                if let Some(rep) = r.get("replay").filter(|v| v.is_object()) {
                    delta = true;
                    rows = rep["messages"].as_array().cloned().unwrap_or_default();
                    let reset: Vec<Value> = rep["truncated"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter(|k| self.in_scope(&[k.as_str()]))
                        .cloned()
                        .collect();
                    if !reset.is_empty() {
                        result["reset_panes"] = json!(reset);
                    }
                    self.message_floor = r["seq"].as_u64().unwrap_or(0);
                }
            }
        }
        if !delta {
            if let Ok(r) = self.gw.core.call("message.snapshot", json!({})).await {
                rows = r["messages"].as_array().cloned().unwrap_or_default();
                self.message_floor = r["seq"].as_u64().unwrap_or(0);
            }
        }
        result["replay"] = json!(if delta { "delta" } else { "full" });
        result["panes"] = json!(self.panes().await.unwrap_or_default());

        let mut out = vec![response(id, Ok(result))];
        let cards = self.gw.core.cards().borrow().clone();
        out.push(self.cards_notify(&cards));
        for row in rows.iter().filter(|r| self.in_scope(&[r["pane_session_key"].as_str(), r["pane_id"].as_str()])) {
            out.push(notify("pane.message", row.clone()));
        }
        if let Who::Device { .. } = self.who {
            if let Some(st) = self.gw.core.first_mate().borrow().clone() {
                out.push(notify("autopilot.state", (*st).clone()));
            }
        }
        out
    }

    /// A device token, or the legacy one (exchanged for a device token).
    fn sign_in_with_token(&mut self, mac: &str, token: &str) -> Result<(Who, Option<String>), &'static str> {
        let mut st = self.gw.store();
        let now = auth::now();
        let found = auth::find_device(&st.state, token).map(|d| (d.id.clone(), d.label.clone(), d.last_seen_at));
        if let Some((dev, label, seen)) = found {
            if now - seen > 60.0 {
                if let Some(d) = st.state.devices.iter_mut().find(|d| d.id == dev) {
                    d.last_seen_at = now;
                }
                let _ = st.save_state();
            }
            return Ok((Who::Device { id: dev, label }, Some(token.to_string())));
        }
        if auth::verify_legacy(&st.secrets.root_secret, &st.secrets.mac_id, mac, token) {
            drop(st);
            let label = device_label(&self.meta.user_agent);
            return Ok(self.new_device(&label, "legacy"));
        }
        Err("invalid")
    }

    fn new_device(&self, label: &str, via: &str) -> (Who, Option<String>) {
        let (device, token) = auth::issue_device(label, via);
        let who = Who::Device { id: device.id.clone(), label: device.label.clone() };
        {
            let mut st = self.gw.store();
            st.state.devices.push(device);
            let _ = st.save_state();
        }
        self.gw.emit(json!({"type": "devices.changed"}));
        (who, Some(token))
    }
}

/// "Safari on iPhone", from a User-Agent.
fn device_label(ua: &str) -> String {
    let os = [("iPhone", "iPhone"), ("iPad", "iPad"), ("Android", "Android"), ("Macintosh", "Mac"), ("Windows", "Windows"), ("Linux", "Linux")]
        .iter()
        .find(|(k, _)| ua.contains(k))
        .map(|(_, v)| *v);
    let browser = [("Edg/", "Edge"), ("Firefox/", "Firefox"), ("CriOS/", "Chrome"), ("Chrome/", "Chrome"), ("Safari/", "Safari")]
        .iter()
        .find(|(k, _)| ua.contains(k))
        .map(|(_, v)| *v);
    match (browser, os) {
        (Some(b), Some(o)) => format!("{b} on {o}"),
        (Some(b), None) => b.to_string(),
        (None, Some(o)) => o.to_string(),
        (None, None) => "browser".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels() {
        assert_eq!(device_label("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0) AppleWebKit Version/17.0 Mobile Safari/604.1"), "Safari on iPhone");
        assert_eq!(device_label("Mozilla/5.0 (Macintosh) Chrome/120 Safari/537"), "Chrome on Mac");
        assert_eq!(device_label(""), "browser");
    }

    #[test]
    fn share_names_both_ids() {
        let s = Shared { key: "k".into(), link_id: "l".into(), pane_id: Some("t1".into()), sender: "a".into() };
        assert!(s.names("k") && s.names("t1") && !s.names("") && !s.names("x"));
    }
}
