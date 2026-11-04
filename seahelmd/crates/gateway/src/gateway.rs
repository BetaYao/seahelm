//! The one shared state: the store, the core link, and the signals the web
//! server, the Telegram adapter and `gateway.sock` pass between them.

use std::sync::{Arc, Mutex, MutexGuard};

use serde_json::{json, Value};
use tokio::sync::{broadcast, watch};

use crate::auth;
use crate::core::Core;
use crate::store::{Config, Store};

/// Connections to close now.
#[derive(Debug, Clone, PartialEq)]
pub enum Kick {
    /// Every connection signed in with this device token.
    Device(String),
    /// Every connection on this share link.
    Share(String),
    /// Everyone (the pairing was rotated).
    All,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct WebStatus {
    pub listening: bool,
    pub port: u16,
    pub error: Option<String>,
    pub clients: usize,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct TelegramStatus {
    pub connected: bool,
    pub bot_username: Option<String>,
    pub error: Option<String>,
}

pub struct Gateway {
    pub core: Core,
    store: Mutex<Store>,
    pub limiter: Mutex<auth::RateLimiter>,
    /// Settings as they are now; the web server and the Telegram adapter
    /// watch it and apply changes live. The bot token rides along so a new
    /// one reconnects the bot.
    config: watch::Sender<(Config, Option<String>)>,
    pub kick: broadcast::Sender<Kick>,
    /// `gateway.sock` events (`gateway.status_changed`, `telegram.paired`, …).
    pub admin_events: broadcast::Sender<Value>,
    pub web_status: Mutex<WebStatus>,
    pub telegram_status: Mutex<TelegramStatus>,
    /// Device id → open connections, for `devices.list`.
    pub connected_devices: Mutex<std::collections::HashMap<String, usize>>,
    pub runtime: tokio::runtime::Handle,
}

impl Gateway {
    pub fn new(core: Core, store: Store, runtime: tokio::runtime::Handle) -> Arc<Gateway> {
        let snapshot = (store.config.clone(), store.bot_token());
        Arc::new(Gateway {
            core,
            store: Mutex::new(store),
            limiter: Mutex::new(auth::RateLimiter::default()),
            config: watch::channel(snapshot).0,
            kick: broadcast::channel(64).0,
            admin_events: broadcast::channel(256).0,
            web_status: Mutex::new(WebStatus::default()),
            telegram_status: Mutex::new(TelegramStatus::default()),
            connected_devices: Mutex::new(Default::default()),
            runtime,
        })
    }

    pub fn store(&self) -> MutexGuard<'_, Store> {
        self.store.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn config(&self) -> watch::Receiver<(Config, Option<String>)> {
        self.config.subscribe()
    }

    /// Tell the watchers the settings (or the bot token) changed.
    pub fn config_changed(&self) {
        let snapshot = {
            let st = self.store();
            (st.config.clone(), st.bot_token())
        };
        self.config.send_if_modified(|cur| {
            if *cur == snapshot {
                return false;
            }
            *cur = snapshot;
            true
        });
        self.emit(json!({"type": "config.changed"}));
    }

    pub fn emit(&self, event: Value) {
        let _ = self.admin_events.send(event);
    }

    pub fn status_changed(&self) {
        self.emit(json!({"type": "gateway.status_changed", "status": self.status()}));
    }

    pub fn status(&self) -> Value {
        let (cfg, token_set) = {
            let st = self.store();
            (st.config.clone(), st.bot_token().is_some())
        };
        let web = self.web_status.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let tg = self.telegram_status.lock().unwrap_or_else(|e| e.into_inner()).clone();
        json!({
            "web": {"enabled": cfg.web.enabled, "listening": web.listening, "port": cfg.web.port,
                    "public_url": self.base_url(), "error": web.error, "clients": web.clients},
            "telegram": {"enabled": cfg.telegram.enabled, "configured": token_set, "connected": tg.connected,
                         "bot_username": tg.bot_username, "error": tg.error},
            "core": {"reachable": self.core.reachable()},
        })
    }

    /// Where links point: `public_url`, else this machine's LAN address.
    pub fn base_url(&self) -> String {
        let (public, port) = {
            let st = self.store();
            (st.config.web.public_url.clone(), st.config.web.port)
        };
        if let Some(p) = public.map(|p| p.trim().trim_end_matches('/').to_string()).filter(|p| !p.is_empty()) {
            return p;
        }
        format!("http://{}:{port}", lan_address().unwrap_or_else(|| "localhost".into()))
    }
}

/// The address this machine reaches the LAN from (no packet is sent).
fn lan_address() -> Option<String> {
    let s = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect("192.0.2.1:9").ok()?;
    let ip = s.local_addr().ok()?.ip();
    (!ip.is_unspecified()).then(|| ip.to_string())
}
