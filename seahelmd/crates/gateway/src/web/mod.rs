//! Web access: seahelm-web's files and its WebSocket on one port
//! (`http://HOST:PORT/`, `ws://HOST:PORT/ws`). The listener follows
//! `config.web` live: enabling, disabling or moving the port rebinds, and
//! every open page is closed (it reconnects by itself).

mod fleet;
mod frames;
mod session;
mod static_files;
mod vt;

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::WebSocketUpgrade;
use axum::extract::{ConnectInfo, State};
use axum::http::{header, HeaderMap, Method, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use serde_json::json;

use crate::gateway::{Gateway, Kick};
use crate::store::WebConfig;

/// First Mate's session: not a pane of the fleet for the page.
pub const FIRST_MATE: &str = "seahelm-first-mate";

#[derive(Clone)]
struct App {
    gw: Arc<Gateway>,
    files: Arc<static_files::StaticFiles>,
    root: Option<std::path::PathBuf>,
}

pub async fn run(gw: Arc<Gateway>) {
    tokio::spawn(sweep_share_links(gw.clone()));
    let files = Arc::new(static_files::StaticFiles::default());
    let mut config = gw.config();
    loop {
        let web = config.borrow_and_update().0.web.clone();
        let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
        let server = if web.enabled { Some(tokio::spawn(serve(gw.clone(), files.clone(), web.clone(), stop_rx))) } else { None };
        if !web.enabled {
            set_status(&gw, false, web.port, None);
        }
        // Until the part that matters to the listener changes.
        loop {
            if config.changed().await.is_err() {
                return;
            }
            if config.borrow().0.web != web {
                break;
            }
        }
        let _ = stop_tx.send(());
        let _ = gw.kick.send(Kick::All);
        if let Some(s) = server {
            let _ = tokio::time::timeout(Duration::from_secs(5), s).await;
        }
    }
}

async fn serve(gw: Arc<Gateway>, files: Arc<static_files::StaticFiles>, web: WebConfig, stop: tokio::sync::oneshot::Receiver<()>) {
    // A port still held by a listener just closed is a slow start: retry briefly.
    let mut listener = None;
    let mut last_err = None;
    for _ in 0..40 {
        match tokio::net::TcpListener::bind(("0.0.0.0", web.port)).await {
            Ok(l) => {
                listener = Some(l);
                break;
            }
            Err(e) => {
                last_err = Some(e.to_string());
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
    let Some(listener) = listener else {
        eprintln!("seahelm-gateway: web: cannot listen on {}: {}", web.port, last_err.clone().unwrap_or_default());
        set_status(&gw, false, web.port, last_err);
        return;
    };
    let root = crate::paths::web_root(web.web_root.as_deref());
    if root.is_none() {
        eprintln!("seahelm-gateway: web: no seahelm-web files found; pages will 404");
    }
    eprintln!("seahelm-gateway: web: listening on {}", web.port);
    set_status(&gw, true, web.port, None);
    let app = Router::new().route("/ws", get(ws)).fallback(static_file).with_state(App { gw: gw.clone(), files, root });
    let result = axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(async move {
            let _ = stop.await;
        })
        .await;
    if let Err(e) = result {
        eprintln!("seahelm-gateway: web: {e}");
    }
    set_status(&gw, false, web.port, None);
}

fn set_status(gw: &Gateway, listening: bool, port: u16, error: Option<String>) {
    {
        let mut st = gw.web_status.lock().unwrap_or_else(|e| e.into_inner());
        st.listening = listening;
        st.port = port;
        st.error = error;
    }
    gw.status_changed();
}

async fn ws(State(app): State<App>, ConnectInfo(peer): ConnectInfo<SocketAddr>, headers: HeaderMap, upgrade: WebSocketUpgrade) -> Response {
    let h = |name: &str| headers.get(name).and_then(|v| v.to_str().ok()).map(str::to_string);
    // Behind the local tunnel every request comes from loopback; the address
    // that means anything is the one Cloudflare saw.
    let relayed = if peer.ip().is_loopback() { h("cf-connecting-ip") } else { None };
    let host = h("host").map(|v| {
        let v = v.to_ascii_lowercase();
        if v.starts_with('[') { v } else { v.split(':').next().unwrap_or("").to_string() }
    });
    let meta = session::Meta { host: host.filter(|h| !h.is_empty()), client_ip: relayed.unwrap_or_else(|| peer.ip().to_string()), user_agent: h("user-agent").unwrap_or_default() };
    let gw = app.gw.clone();
    upgrade.max_message_size(16 << 20).on_upgrade(move |socket| session::run(gw, socket, meta))
}

async fn static_file(State(app): State<App>, method: Method, uri: Uri, headers: HeaderMap) -> Response {
    let h = |name: header::HeaderName| headers.get(name).and_then(|v| v.to_str().ok()).map(str::to_string);
    let target = uri.path_and_query().map(|p| p.as_str().to_string()).unwrap_or_else(|| "/".into());
    let files = app.files.clone();
    let root = app.root.clone();
    let method_s = method.as_str().to_string();
    let (ae, inm) = (h(header::ACCEPT_ENCODING), h(header::IF_NONE_MATCH));
    let r = tokio::task::spawn_blocking(move || files.response(root.as_deref(), &method_s, &target, ae.as_deref(), inm.as_deref())).await;
    let Ok(r) = r else { return StatusCode::INTERNAL_SERVER_ERROR.into_response() };
    let mut resp = (StatusCode::from_u16(r.status).unwrap_or(StatusCode::OK), if method == Method::HEAD { Vec::new() } else { r.body }).into_response();
    let hs = resp.headers_mut();
    hs.insert(header::CONTENT_TYPE, header::HeaderValue::from_static(r.content_type));
    hs.insert(header::CACHE_CONTROL, header::HeaderValue::from_static(r.cache_control));
    if let Some(enc) = r.content_encoding {
        hs.insert(header::CONTENT_ENCODING, header::HeaderValue::from_static(enc));
        hs.insert(header::VARY, header::HeaderValue::from_static("Accept-Encoding"));
    }
    if let Some(tag) = r.etag.and_then(|t| header::HeaderValue::from_str(&t).ok()) {
        hs.insert(header::ETAG, tag);
    }
    resp
}

/// Close pages on a link that ran out, and drop it from the store.
async fn sweep_share_links(gw: Arc<Gateway>) {
    let mut tick = tokio::time::interval(Duration::from_secs(30));
    loop {
        tick.tick().await;
        let now = crate::auth::now();
        let expired: Vec<String> = {
            let mut st = gw.store();
            let gone: Vec<String> = st.state.share_links.iter().filter(|l| !l.is_live(now)).map(|l| l.id.clone()).collect();
            if !gone.is_empty() {
                st.state.share_links.retain(|l| l.is_live(now));
                let _ = st.save_state();
            }
            gone
        };
        for id in &expired {
            let _ = gw.kick.send(Kick::Share(id.clone()));
        }
        if !expired.is_empty() {
            gw.emit(json!({"type": "share.changed"}));
        }
    }
}
