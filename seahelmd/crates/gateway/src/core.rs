//! The gateway's link to seahelm-core: calls, and the streams it follows.
//! To the core the gateway is one more client; it uses public methods only
//! (docs/target-architecture.html).
//!
//! Two subscriptions run on threads of their own and reconnect forever:
//! `events.subscribe` (everything the registry publishes) and
//! `message.subscribe` (timeline rows). What they bring is fanned out to the
//! web sessions and the Telegram adapter through broadcast channels, and the
//! cards and First Mate's state are kept current in watch channels so a
//! connection arriving late gets them at once.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};
use tokio::sync::{broadcast, watch};

use crate::rpc::{self, RpcError, RpcResult};

#[derive(Clone)]
pub struct Core {
    inner: Arc<Inner>,
}

struct Inner {
    socket: PathBuf,
    reachable: AtomicBool,
    events: broadcast::Sender<Arc<Value>>,
    messages: broadcast::Sender<Arc<Value>>,
    /// The latest timeline seq seen, so a reconnect asks for what came after.
    message_seq: AtomicU64,
    cards: watch::Sender<Arc<Vec<Value>>>,
    first_mate: watch::Sender<Option<Arc<Value>>>,
}

impl Core {
    pub fn new(socket: PathBuf) -> Core {
        Core {
            inner: Arc::new(Inner {
                socket,
                reachable: AtomicBool::new(false),
                events: broadcast::channel(4096).0,
                messages: broadcast::channel(4096).0,
                message_seq: AtomicU64::new(0),
                cards: watch::channel(Arc::new(Vec::new())).0,
                first_mate: watch::channel(None).0,
            }),
        }
    }

    pub fn reachable(&self) -> bool {
        self.inner.reachable.load(Ordering::Relaxed)
    }

    /// Every event the core publishes (`pane.*`, `cards.changed`,
    /// `card.answered`, `autopilot.audit`, …), in its own shape.
    pub fn events(&self) -> broadcast::Receiver<Arc<Value>> {
        self.inner.events.subscribe()
    }

    /// Every new timeline row.
    pub fn messages(&self) -> broadcast::Receiver<Arc<Value>> {
        self.inner.messages.subscribe()
    }

    pub fn cards(&self) -> watch::Receiver<Arc<Vec<Value>>> {
        self.inner.cards.subscribe()
    }

    pub fn first_mate(&self) -> watch::Receiver<Option<Arc<Value>>> {
        self.inner.first_mate.subscribe()
    }

    /// A call, blocking. For threads; async code uses `call`.
    pub fn call_blocking(&self, method: &str, params: Value, timeout: Duration) -> RpcResult {
        match rpc::call(&self.inner.socket, method, params, timeout) {
            Ok(r) => r,
            Err(e) => Err(RpcError::new(-32000, format!("seahelm-core unavailable: {e}"))),
        }
    }

    /// A call to the core, off the async runtime.
    pub async fn call(&self, method: &str, params: Value) -> RpcResult {
        let timeout = match method {
            "worktree.create" | "pane.new" => Duration::from_secs(120),
            _ => Duration::from_secs(10),
        };
        let core = self.clone();
        let method = method.to_string();
        tokio::task::spawn_blocking(move || core.call_blocking(&method, params, timeout))
            .await
            .unwrap_or_else(|e| Err(RpcError::internal(e.to_string())))
    }

    /// Start following the core. Returns at once.
    pub fn start(&self) {
        let me = self.clone();
        std::thread::Builder::new().name("gateway-core-events".into()).spawn(move || me.follow_events()).expect("spawn");
        let me = self.clone();
        std::thread::Builder::new().name("gateway-core-messages".into()).spawn(move || me.follow_messages()).expect("spawn");
        let me = self.clone();
        std::thread::Builder::new().name("gateway-first-mate".into()).spawn(move || me.poll_first_mate()).expect("spawn");
    }

    fn follow_events(self) {
        loop {
            // Cards first, so the list is current before the stream says it changed.
            if let Ok(r) = self.call_blocking("cards.list", json!({}), Duration::from_secs(5)) {
                self.set_cards(&r["cards"]);
            }
            let result = rpc::stream(&self.inner.socket, "events.subscribe", json!({}), |line| {
                if line.get("result").is_some() {
                    self.inner.reachable.store(true, Ordering::Relaxed);
                    return true;
                }
                if line.get("method").and_then(Value::as_str) != Some("event") {
                    return true;
                }
                let ev = line.get("params").cloned().unwrap_or(Value::Null);
                if ev.get("type").and_then(Value::as_str) == Some("cards.changed") {
                    self.set_cards(&ev["cards"]);
                }
                let _ = self.inner.events.send(Arc::new(ev));
                true
            });
            self.inner.reachable.store(false, Ordering::Relaxed);
            if let Err(e) = result {
                eprintln!("seahelm-gateway: core events: {e}");
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    }

    fn set_cards(&self, cards: &Value) {
        let list = cards.as_array().cloned().unwrap_or_default();
        self.inner.cards.send_if_modified(|cur| {
            if **cur == list {
                return false;
            }
            *cur = Arc::new(list);
            true
        });
    }

    fn follow_messages(self) {
        loop {
            let after = self.inner.message_seq.load(Ordering::Relaxed);
            let params = if after > 0 { json!({"after_seq": after}) } else { json!({}) };
            let result = rpc::stream(&self.inner.socket, "message.subscribe", params, |line| {
                if let Some(r) = line.get("result") {
                    if let Some(seq) = r.get("seq").and_then(Value::as_u64) {
                        if after == 0 || r.get("reset").is_some() {
                            self.inner.message_seq.store(seq, Ordering::Relaxed);
                        }
                    }
                    return true;
                }
                if line.get("method").and_then(Value::as_str) != Some("message") {
                    return true;
                }
                let row = line.get("params").cloned().unwrap_or(Value::Null);
                if let Some(seq) = row.get("seq").and_then(Value::as_u64) {
                    self.inner.message_seq.fetch_max(seq, Ordering::Relaxed);
                }
                let _ = self.inner.messages.send(Arc::new(row));
                true
            });
            if let Err(e) = result {
                eprintln!("seahelm-gateway: core messages: {e}");
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    }

    /// `autopilot.state` every 2 s; subscribers hear only changes.
    fn poll_first_mate(self) {
        loop {
            let state = self.call_blocking("autopilot.state", json!({}), Duration::from_secs(5)).ok().map(Arc::new);
            self.inner.first_mate.send_if_modified(|cur| {
                if cur.as_deref() == state.as_deref() {
                    return false;
                }
                *cur = state;
                true
            });
            std::thread::sleep(Duration::from_secs(2));
        }
    }
}
