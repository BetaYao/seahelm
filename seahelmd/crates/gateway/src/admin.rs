//! `gateway.sock`: the local admin face the app, the GPUI client and the
//! CLI use for settings, pairing, devices and share links
//! (docs/seahelm-gateway-plan.md). Business calls never come through here.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};

use crate::auth;
use crate::gateway::{Gateway, Kick};
use crate::rpc::{self, Reply, RpcError, RpcResult};

pub fn spawn(gw: Arc<Gateway>) -> anyhow::Result<()> {
    let listener = rpc::bind(&crate::paths::gateway_socket())?;
    let dispatch: Arc<dyn Fn(&str, Value) -> Reply + Send + Sync> = Arc::new(move |method, params| call(&gw, method, params));
    std::thread::Builder::new().name("gateway-admin-accept".into()).spawn(move || rpc::serve(listener, dispatch))?;
    Ok(())
}

fn s(p: &Value, k: &str) -> Option<String> {
    p.get(k).and_then(Value::as_str).map(str::to_string)
}

pub fn call(gw: &Arc<Gateway>, method: &str, p: Value) -> Reply {
    if method == "events.subscribe" {
        let mut rx = gw.admin_events.subscribe();
        return Reply::Stream(Box::new(move |w| {
            if rpc::write_line(w, &json!({"jsonrpc": "2.0", "id": null, "result": {"subscribed": true}})).is_err() {
                return;
            }
            loop {
                let next = rx.blocking_recv_timeout(Duration::from_secs(15));
                let msg = match next {
                    Some(Ok(ev)) => json!({"jsonrpc": "2.0", "method": "event", "params": ev}),
                    Some(Err(())) => return,
                    None => json!({"jsonrpc": "2.0", "method": "ping"}),
                };
                if rpc::write_line(w, &msg).is_err() {
                    return;
                }
            }
        }));
    }
    if let Some(r) = crate::telegram::admin(gw, method, &p) {
        return Reply::Value(r);
    }
    Reply::Value(dispatch(gw, method, &p))
}

fn dispatch(gw: &Arc<Gateway>, method: &str, p: &Value) -> RpcResult {
    match method {
        "gateway.ping" => Ok(json!({"ok": true, "version": env!("CARGO_PKG_VERSION"), "pid": std::process::id()})),
        "gateway.status" => Ok(gw.status()),
        "gateway.config.get" => Ok(config_json(gw)),
        "gateway.config.set" => {
            {
                let mut st = gw.store();
                if let Some(web) = p.get("web").and_then(Value::as_object) {
                    let mut cur = serde_json::to_value(&st.config.web).unwrap_or_default();
                    for (k, v) in web {
                        cur[k] = v.clone();
                    }
                    st.config.web = serde_json::from_value(cur).map_err(|e| RpcError::invalid_params(format!("web: {e}")))?;
                }
                if let Some(tg) = p.get("telegram").and_then(Value::as_object) {
                    let mut cur = serde_json::to_value(&st.config.telegram).unwrap_or_default();
                    for (k, v) in tg {
                        if k == "bot_token" {
                            continue;
                        }
                        cur[k] = v.clone();
                    }
                    st.config.telegram = serde_json::from_value(cur).map_err(|e| RpcError::invalid_params(format!("telegram: {e}")))?;
                    if let Some(token) = tg.get("bot_token").and_then(Value::as_str) {
                        let t = token.trim();
                        st.secrets.telegram_bot_token = (!t.is_empty()).then(|| t.to_string());
                        st.save_secrets().map_err(|e| RpcError::internal(e.to_string()))?;
                    }
                }
                st.save_config().map_err(|e| RpcError::internal(e.to_string()))?;
            }
            gw.config_changed();
            Ok(config_json(gw))
        }
        "pairing.code.get" => Ok(code_json(gw)),
        "pairing.code.refresh" => {
            {
                let mut st = gw.store();
                st.secrets.pair_code = Some(auth::generate_code());
                st.save_secrets().map_err(|e| RpcError::internal(e.to_string()))?;
            }
            Ok(code_json(gw))
        }
        "pairing.code.set" => {
            let code = auth::normalize_code(&s(p, "code").unwrap_or_default());
            if !auth::is_valid_code(&code) {
                return Err(RpcError::invalid_params("a code is 8 to 16 digits"));
            }
            {
                let mut st = gw.store();
                st.secrets.pair_code = Some(code);
                st.save_secrets().map_err(|e| RpcError::internal(e.to_string()))?;
            }
            Ok(code_json(gw))
        }
        "pairing.revoke_all" => {
            {
                let mut st = gw.store();
                st.secrets.root_secret = auth::new_root_secret();
                st.secrets.pair_code = Some(auth::generate_code());
                st.state.devices.clear();
                st.save_secrets().map_err(|e| RpcError::internal(e.to_string()))?;
                st.save_state().map_err(|e| RpcError::internal(e.to_string()))?;
            }
            let _ = gw.kick.send(Kick::All);
            gw.emit(json!({"type": "devices.changed"}));
            Ok(json!({"ok": true}))
        }
        "devices.list" => {
            let connected = gw.connected_devices.lock().unwrap_or_else(|e| e.into_inner()).clone();
            let st = gw.store();
            let devices: Vec<Value> = st
                .state
                .devices
                .iter()
                .map(|d| {
                    json!({"id": d.id, "label": d.label, "via": d.via, "created_at": d.created_at,
                           "last_seen_at": d.last_seen_at, "connected": connected.get(&d.id).copied().unwrap_or(0) > 0})
                })
                .collect();
            Ok(json!({"devices": devices}))
        }
        "devices.revoke" => {
            let id = s(p, "id").ok_or_else(|| RpcError::invalid_params("id required"))?;
            let removed = {
                let mut st = gw.store();
                let before = st.state.devices.len();
                st.state.devices.retain(|d| d.id != id);
                let removed = st.state.devices.len() != before;
                if removed {
                    st.save_state().map_err(|e| RpcError::internal(e.to_string()))?;
                }
                removed
            };
            if removed {
                let _ = gw.kick.send(Kick::Device(id));
                gw.emit(json!({"type": "devices.changed"}));
            }
            Ok(json!({"ok": removed}))
        }
        "share.create" => {
            let pane = s(p, "pane_session_key").filter(|k| !k.is_empty()).ok_or_else(|| RpcError::invalid_params("pane_session_key required"))?;
            let label = s(p, "label").unwrap_or_default();
            let lifetime = p.get("lifetime_seconds").and_then(Value::as_f64);
            let recipient = s(p, "recipient");
            let (link, token) = auth::mint_share(&pane, &label, lifetime, recipient.as_deref());
            {
                let mut st = gw.store();
                st.state.share_links.push(link.clone());
                st.save_state().map_err(|e| RpcError::internal(e.to_string()))?;
            }
            gw.emit(json!({"type": "share.changed"}));
            let url = share_url(gw, &pane, &token);
            Ok(json!({"id": link.id, "url": url, "expires_at": link.expires_at}))
        }
        "share.list" => {
            let now = auth::now();
            let mut st = gw.store();
            let before = st.state.share_links.len();
            st.state.share_links.retain(|l| l.is_live(now));
            if st.state.share_links.len() != before {
                let _ = st.save_state();
            }
            let mut links: Vec<Value> = st.state.share_links.iter().map(link_json).collect();
            links.reverse();
            Ok(json!({"links": links}))
        }
        "share.update" => {
            let id = s(p, "id").ok_or_else(|| RpcError::invalid_params("id required"))?;
            let (link, rebound) = {
                let mut st = gw.store();
                let Some(l) = st.state.share_links.iter_mut().find(|l| l.id == id) else {
                    return Err(RpcError::invalid_params("no such link"));
                };
                if let Some(v) = p.get("lifetime_seconds") {
                    l.expires_at = v.as_f64().map(|s| auth::now() + s);
                }
                let mut rebound = false;
                if let Some(v) = p.get("recipient") {
                    let next = v.as_str().and_then(auth::sender_name);
                    rebound = next != l.recipient;
                    l.recipient = next;
                }
                let link = l.clone();
                st.save_state().map_err(|e| RpcError::internal(e.to_string()))?;
                (link, rebound)
            };
            // A link bound to someone else drops pages open under another name;
            // a shortened one is checked by the expiry sweep.
            if rebound {
                let _ = gw.kick.send(Kick::Share(id));
            }
            gw.emit(json!({"type": "share.changed"}));
            Ok(link_json(&link))
        }
        "share.revoke" => {
            let id = s(p, "id");
            let pane = s(p, "pane_session_key");
            if id.is_none() && pane.is_none() {
                return Err(RpcError::invalid_params("id or pane_session_key required"));
            }
            let gone: Vec<String> = {
                let mut st = gw.store();
                let gone = st
                    .state
                    .share_links
                    .iter()
                    .filter(|l| id.as_deref() == Some(&l.id) || pane.as_deref() == Some(&l.pane_session_key))
                    .map(|l| l.id.clone())
                    .collect::<Vec<_>>();
                st.state.share_links.retain(|l| !gone.contains(&l.id));
                st.save_state().map_err(|e| RpcError::internal(e.to_string()))?;
                gone
            };
            for g in &gone {
                let _ = gw.kick.send(Kick::Share(g.clone()));
            }
            gw.emit(json!({"type": "share.changed"}));
            Ok(json!({"ok": !gone.is_empty()}))
        }
        other => Err(RpcError::not_found(other)),
    }
}

fn link_json(l: &crate::store::ShareLink) -> Value {
    json!({"id": l.id, "pane_session_key": l.pane_session_key, "label": l.label, "recipient": l.recipient,
           "created_at": l.created_at, "expires_at": l.expires_at})
}

pub fn share_url(gw: &Gateway, pane: &str, token: &str) -> String {
    let enc = |v: &str| percent_encoding::utf8_percent_encode(v, percent_encoding::NON_ALPHANUMERIC).to_string();
    format!("{}/?pane={}&share={}", gw.base_url(), enc(pane), enc(token))
}

fn code_json(gw: &Gateway) -> Value {
    let code = gw.store().secrets.pair_code.clone().unwrap_or_default();
    json!({"code": code, "pair_url": gw.base_url()})
}

fn config_json(gw: &Gateway) -> Value {
    let st = gw.store();
    let mut tg = serde_json::to_value(&st.config.telegram).unwrap_or_default();
    tg["bot_token_set"] = json!(st.bot_token().is_some());
    json!({"web": st.config.web, "telegram": tg})
}

/// `blocking_recv` with a timeout, for the admin threads: `Some(Err)` when
/// the channel is gone, `None` on timeout.
trait RecvTimeout {
    fn blocking_recv_timeout(&mut self, d: Duration) -> Option<Result<Value, ()>>;
}

impl RecvTimeout for tokio::sync::broadcast::Receiver<Value> {
    fn blocking_recv_timeout(&mut self, d: Duration) -> Option<Result<Value, ()>> {
        let deadline = std::time::Instant::now() + d;
        loop {
            match self.try_recv() {
                Ok(v) => return Some(Ok(v)),
                Err(tokio::sync::broadcast::error::TryRecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::TryRecvError::Closed) => return Some(Err(())),
                Err(tokio::sync::broadcast::error::TryRecvError::Empty) => {
                    if std::time::Instant::now() >= deadline {
                        return None;
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
            }
        }
    }
}
