//! Remote screen (docs/superpowers/specs/2026-11-22-remote-screen-design.md):
//! the macOS app captures the display and injects input; the gateway only
//! authorises pages, relays the latest frame to each and passes their input
//! back.
//!
//! The app connects to `screen.sock` (`paths::screen_socket`, 0600) as the
//! one provider. Both directions carry length-prefixed messages,
//! `[u32 BE length][u8 type][payload]` (the length counts the type byte):
//! type 1 is a JSON object, type 2 (app → gateway only) a frame,
//! `[u8 codec][u8 flags][u16 BE width][u16 BE height]` then the encoded
//! picture.
//!
//! Gateway → app: `{"type":"watch","fps","max_short","kbps","codec",
//! "quality","viewers"}` (fps 0: nobody watches, stop capturing; codec `h264`
//! when every viewer decodes it, else `jpeg`), `{"type":"key_frame"}` (a
//! viewer joined or lost frames: the next H.264 frame must be a key frame),
//! and the pages' input verbatim (`pointer`, `scroll`, `key`, `text`,
//! `clipboard` — text to put on the Mac's clipboard). `watch` also names the
//! display a page picked (`display`, a CGDirectDisplayID; null: the main
//! one).
//! App → gateway: `{"type":"error","message"}` (shown on the pages),
//! `{"type":"stop"}` (the user ended it on the Mac),
//! `{"type":"displays","list":[{id,name,width,height,main}],"current"}`
//! (the displays there are and the one captured), `{"type":"clipboard",
//! "text"}` (the Mac's clipboard changed while someone watches).
//!
//! Each page gets the newest frame, never a queue. That is lossless for
//! JPEG; for H.264 a skipped frame breaks the chain, so the page's session
//! then sends nothing until a key frame and asks the app for one
//! (`request_key_frame`, at most every `KEY_FRAME_EVERY`).

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use tokio::sync::{mpsc, watch};

#[cfg(test)]
const CODEC_JPEG: u8 = 1;
pub const CODEC_H264: u8 = 2;
/// Key frames are big: a page that keeps falling behind asks for one at
/// most this often.
const KEY_FRAME_EVERY: std::time::Duration = std::time::Duration::from_millis(700);
const TYPE_JSON: u8 = 1;
const TYPE_FRAME: u8 = 2;
/// A 6K display as an uncompressed-ish JPEG stays well under this.
const MAX_MESSAGE: usize = 32 << 20;

const DEFAULT_FPS: u32 = 4;
const MAX_FPS: u32 = 60;
const DEFAULT_MAX_SHORT: u32 = 1080;
const DEFAULT_KBPS: u32 = 3000;
const MIN_KBPS: u32 = 300;
/// The Mac's clipboard as text, at most this much, both ways.
pub const MAX_CLIPBOARD: usize = 256 << 10;

#[derive(Debug, Clone, PartialEq)]
pub struct Frame {
    pub codec: u8,
    pub key: bool,
    pub width: u16,
    pub height: u16,
    pub data: Vec<u8>,
}

/// What every watching page follows.
#[derive(Debug, Clone, Default)]
pub struct Shared {
    /// The newest frame; a page that falls behind skips to it.
    pub frame: Option<Arc<Frame>>,
    /// Counts frames, so a page can tell a new one from the one it sent.
    pub seq: u64,
    pub provider: bool,
    pub error: Option<String>,
    /// Bumped when every viewer is sent away (the user stopped it on the Mac,
    /// or turned the feature off); a page opened under an older epoch closes.
    pub epoch: u64,
    /// `{list, current}` as the app last reported them.
    pub displays: Option<Arc<Value>>,
    pub displays_seq: u64,
    /// The Mac's clipboard text, as the app last reported it.
    pub clipboard: Option<Arc<String>>,
    pub clipboard_seq: u64,
}

#[derive(Debug, Clone)]
struct Viewer {
    label: String,
    fps: u32,
    max_short: u32,
    kbps: u32,
    h264: bool,
}

/// What a page asks for in `screen.open` / `screen.quality`.
#[derive(Debug, Clone, Default)]
pub struct Ask {
    pub fps: Option<u32>,
    pub max_short: Option<u32>,
    pub kbps: Option<u32>,
    /// The codecs it decodes; None: JPEG only (a phase-1 page).
    pub codecs: Option<Vec<String>>,
}

pub struct ScreenHub {
    state: watch::Sender<Shared>,
    provider: Mutex<Option<mpsc::UnboundedSender<Value>>>,
    viewers: Mutex<BTreeMap<u64, Viewer>>,
    next_id: AtomicU64,
    last_key_request: Mutex<Option<std::time::Instant>>,
    /// The display a page picked; None: the main one.
    display: Mutex<Option<u64>>,
}

/// A page's open screen: dropping it closes it.
pub struct Watching {
    hub: Arc<ScreenHub>,
    pub id: u64,
    pub epoch: u64,
}

impl Drop for Watching {
    fn drop(&mut self) {
        self.hub.close(self.id);
    }
}

impl ScreenHub {
    pub fn new() -> Arc<ScreenHub> {
        Arc::new(ScreenHub {
            state: watch::channel(Shared::default()).0,
            provider: Mutex::new(None),
            viewers: Mutex::new(BTreeMap::new()),
            next_id: AtomicU64::new(1),
            last_key_request: Mutex::new(None),
            display: Mutex::new(None),
        })
    }

    pub fn provider_connected(&self) -> bool {
        self.state.borrow().provider
    }

    pub fn viewer_labels(&self) -> Vec<String> {
        self.viewers.lock().unwrap_or_else(|e| e.into_inner()).values().map(|v| v.label.clone()).collect()
    }

    /// Start watching for one page. Err: why not (no app to capture).
    pub fn open(self: &Arc<Self>, label: &str, ask: &Ask) -> Result<(Watching, watch::Receiver<Shared>), &'static str> {
        if !self.provider_connected() {
            return Err("seahelm is not running on this Mac");
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let viewer = Viewer {
            label: label.to_string(),
            fps: ask.fps.unwrap_or(DEFAULT_FPS).clamp(1, MAX_FPS),
            max_short: ask.max_short.unwrap_or(DEFAULT_MAX_SHORT).clamp(240, 2880),
            kbps: ask.kbps.unwrap_or(DEFAULT_KBPS).clamp(300, 20000),
            h264: ask.codecs.as_ref().is_some_and(|c| c.iter().any(|c| c == "h264")),
        };
        self.viewers.lock().unwrap_or_else(|e| e.into_inner()).insert(id, viewer);
        let mut rx = self.state.subscribe();
        // The newest frame goes out at once, not with the next one.
        rx.mark_changed();
        let epoch = rx.borrow().epoch;
        self.retune();
        // A newcomer can only start decoding H.264 at a key frame.
        self.request_key_frame();
        Ok((Watching { hub: self.clone(), id, epoch }, rx))
    }

    pub fn set_quality(&self, id: u64, ask: &Ask) {
        {
            let mut v = self.viewers.lock().unwrap_or_else(|e| e.into_inner());
            let Some(viewer) = v.get_mut(&id) else { return };
            if let Some(f) = ask.fps {
                viewer.fps = f.clamp(1, MAX_FPS);
            }
            if let Some(m) = ask.max_short {
                viewer.max_short = m.clamp(240, 2880);
            }
            if let Some(k) = ask.kbps {
                viewer.kbps = k.clamp(300, 20000);
            }
        }
        self.retune();
    }

    /// Capture `id` (a display the app listed) for everyone; None: the main
    /// display. One picture is shared, so the last page to pick wins.
    pub fn choose_display(&self, id: Option<u64>) {
        *self.display.lock().unwrap_or_else(|e| e.into_inner()) = id;
        self.retune();
        self.request_key_frame();
    }

    /// Ask the app for a key frame, unless one was asked for just now.
    pub fn request_key_frame(&self) {
        {
            let mut last = self.last_key_request.lock().unwrap_or_else(|e| e.into_inner());
            if last.is_some_and(|t| t.elapsed() < KEY_FRAME_EVERY) {
                return;
            }
            *last = Some(std::time::Instant::now());
        }
        self.input(json!({"type": "key_frame"}));
    }

    fn close(&self, id: u64) {
        let removed = self.viewers.lock().unwrap_or_else(|e| e.into_inner()).remove(&id).is_some();
        if removed {
            self.retune();
        }
    }

    /// Send every viewer away.
    pub fn stop_all(&self) {
        let had = {
            let mut v = self.viewers.lock().unwrap_or_else(|e| e.into_inner());
            let had = !v.is_empty();
            v.clear();
            had
        };
        self.state.send_modify(|s| {
            s.epoch += 1;
            s.frame = None;
        });
        if had {
            self.retune();
        }
    }

    /// Pass a page's input to the app. False when there is no app.
    pub fn input(&self, msg: Value) -> bool {
        let p = self.provider.lock().unwrap_or_else(|e| e.into_inner());
        p.as_ref().is_some_and(|tx| tx.send(msg).is_ok())
    }

    /// Tell the app what the viewers want: the most any of them asked for.
    fn retune(&self) {
        let msg = {
            let v = self.viewers.lock().unwrap_or_else(|e| e.into_inner());
            let fps = v.values().map(|x| x.fps).max().unwrap_or(0);
            let max_short = v.values().map(|x| x.max_short).max().unwrap_or(0);
            // One stream for all: the thinnest link sets the bitrate.
            let kbps = v.values().map(|x| x.kbps).min().unwrap_or(0);
            let codec = if !v.is_empty() && v.values().all(|x| x.h264) { "h264" } else { "jpeg" };
            let labels: Vec<&str> = v.values().map(|x| x.label.as_str()).collect();
            let display = *self.display.lock().unwrap_or_else(|e| e.into_inner());
            json!({"type": "watch", "fps": fps, "max_short": max_short, "kbps": kbps, "codec": codec, "quality": 0.6,
                   "viewers": labels, "display": display})
        };
        if msg["fps"] == 0 {
            self.state.send_modify(|s| s.frame = None);
            // Nobody left to pick: the next session starts on the main display.
            *self.display.lock().unwrap_or_else(|e| e.into_inner()) = None;
        }
        self.input(msg);
    }

    fn provider_up(&self, tx: mpsc::UnboundedSender<Value>) -> bool {
        let mut p = self.provider.lock().unwrap_or_else(|e| e.into_inner());
        if p.as_ref().is_some_and(|t| !t.is_closed()) {
            return false;
        }
        *p = Some(tx);
        drop(p);
        self.state.send_modify(|s| {
            s.provider = true;
            s.error = None;
        });
        self.retune();
        true
    }

    fn provider_down(&self) {
        *self.provider.lock().unwrap_or_else(|e| e.into_inner()) = None;
        self.state.send_modify(|s| {
            s.provider = false;
            s.frame = None;
        });
    }

    fn frame(&self, f: Frame) {
        if self.viewers.lock().unwrap_or_else(|e| e.into_inner()).is_empty() {
            return;
        }
        self.state.send_modify(|s| {
            s.frame = Some(Arc::new(f));
            s.seq += 1;
            s.error = None;
        });
    }

    fn provider_message(&self, msg: &Value) {
        match msg["type"].as_str() {
            Some("error") => {
                let m = msg["message"].as_str().unwrap_or("capture failed").to_string();
                self.state.send_modify(|s| s.error = Some(m));
            }
            Some("stop") => self.stop_all(),
            Some("displays") => {
                let v = Arc::new(json!({"list": msg["list"].as_array().cloned().unwrap_or_default(), "current": msg["current"]}));
                self.state.send_modify(|s| {
                    if s.displays.as_deref() != Some(&*v) {
                        s.displays = Some(v);
                        s.displays_seq += 1;
                    }
                });
            }
            Some("clipboard") => {
                let Some(t) = msg["text"].as_str().filter(|t| t.len() <= MAX_CLIPBOARD) else { return };
                let t = Arc::new(t.to_string());
                self.state.send_modify(|s| {
                    if s.clipboard.as_deref() != Some(&*t) {
                        s.clipboard = Some(t);
                        s.clipboard_seq += 1;
                    }
                });
            }
            _ => {}
        }
    }
}

/// One page's share of the bitrate, following its link: frames it had to
/// skip (its socket was still busy with older ones) mean the link carries
/// less than asked, so its kbps drops by 30%; a quiet spell brings it back up
/// a quarter at a time, never past what the page asked for.
#[derive(Debug, Clone)]
pub struct Adapt {
    asked: u32,
    now: u32,
    skips: Vec<std::time::Instant>,
    last_skip: Option<std::time::Instant>,
    changed: std::time::Instant,
}

impl Adapt {
    const SKIP_WINDOW: std::time::Duration = std::time::Duration::from_secs(3);
    const SKIPS_TO_DROP: usize = 2;
    const DROP_GAP: std::time::Duration = std::time::Duration::from_secs(2);
    const CALM_TO_RAISE: std::time::Duration = std::time::Duration::from_secs(10);

    pub fn new(asked: Option<u32>, t: std::time::Instant) -> Adapt {
        let asked = asked.unwrap_or(DEFAULT_KBPS).clamp(MIN_KBPS, 20000);
        Adapt { asked, now: asked, skips: Vec::new(), last_skip: None, changed: t }
    }

    pub fn kbps(&self) -> u32 {
        self.now
    }

    /// The page asked for another rate: start again from it.
    pub fn ask(&mut self, kbps: u32, t: std::time::Instant) {
        *self = Adapt::new(Some(kbps), t);
    }

    /// A frame had to be skipped. Some(new kbps) when that lowers it.
    pub fn skipped(&mut self, t: std::time::Instant) -> Option<u32> {
        self.last_skip = Some(t);
        self.skips.retain(|s| t.duration_since(*s) < Self::SKIP_WINDOW);
        self.skips.push(t);
        if self.skips.len() < Self::SKIPS_TO_DROP || t.duration_since(self.changed) < Self::DROP_GAP || self.now <= MIN_KBPS {
            return None;
        }
        self.now = (self.now * 7 / 10).max(MIN_KBPS);
        self.changed = t;
        self.skips.clear();
        Some(self.now)
    }

    /// A frame went out. Some(new kbps) when a calm spell raises it.
    pub fn delivered(&mut self, t: std::time::Instant) -> Option<u32> {
        let calm = |since: std::time::Instant| t.duration_since(since) >= Self::CALM_TO_RAISE;
        if self.now >= self.asked || !calm(self.changed) || self.last_skip.is_some_and(|s| !calm(s)) {
            return None;
        }
        self.now = (self.now * 5 / 4).min(self.asked);
        self.changed = t;
        Some(self.now)
    }
}

/// A frame as the page reads it: binary kind 3,
/// `u8 version=1, u8 flags (bit 0 key frame), u8 kind=3, u8 codec,
///  u16 BE width, u16 BE height, payload`.
pub fn encode_for_page(f: &Frame) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + f.data.len());
    out.extend_from_slice(&[1, u8::from(f.key), 3, f.codec]);
    out.extend_from_slice(&f.width.to_be_bytes());
    out.extend_from_slice(&f.height.to_be_bytes());
    out.extend_from_slice(&f.data);
    out
}

fn parse_frame(payload: &[u8]) -> Option<Frame> {
    if payload.len() < 6 {
        return None;
    }
    Some(Frame {
        codec: payload[0],
        key: payload[1] & 1 == 1,
        width: u16::from_be_bytes([payload[2], payload[3]]),
        height: u16::from_be_bytes([payload[4], payload[5]]),
        data: payload[6..].to_vec(),
    })
}

fn encode_json(v: &Value) -> Vec<u8> {
    let body = v.to_string().into_bytes();
    let mut out = Vec::with_capacity(5 + body.len());
    out.extend_from_slice(&((body.len() + 1) as u32).to_be_bytes());
    out.push(TYPE_JSON);
    out.extend_from_slice(&body);
    out
}

/// Listen on `screen.sock` for the app.
#[cfg(unix)]
pub fn spawn(hub: Arc<ScreenHub>) -> anyhow::Result<()> {
    use anyhow::Context;
    let path = crate::paths::screen_socket();
    if std::os::unix::net::UnixStream::connect(&path).is_ok() {
        anyhow::bail!("screen socket busy at {}", path.display());
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    let _ = std::fs::remove_file(&path);
    let listener = tokio::net::UnixListener::bind(&path).with_context(|| format!("bind {}", path.display()))?;
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { continue };
            tokio::spawn(provider(hub.clone(), stream));
        }
    });
    Ok(())
}

#[cfg(unix)]
async fn provider(hub: Arc<ScreenHub>, stream: tokio::net::UnixStream) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let (mut rd, mut wr) = stream.into_split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Value>();
    if !hub.provider_up(tx) {
        eprintln!("seahelm-gateway: screen: a second provider refused");
        let _ = wr.write_all(&encode_json(&json!({"type": "refused", "reason": "another provider is connected"}))).await;
        return;
    }
    eprintln!("seahelm-gateway: screen: provider connected");
    let writer = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if wr.write_all(&encode_json(&msg)).await.is_err() {
                return;
            }
        }
    });
    loop {
        let mut len = [0u8; 4];
        if rd.read_exact(&mut len).await.is_err() {
            break;
        }
        let len = u32::from_be_bytes(len) as usize;
        if len == 0 || len > MAX_MESSAGE {
            eprintln!("seahelm-gateway: screen: bad message length {len}");
            break;
        }
        let mut buf = vec![0u8; len];
        if rd.read_exact(&mut buf).await.is_err() {
            break;
        }
        match buf[0] {
            TYPE_JSON => {
                if let Ok(v) = serde_json::from_slice::<Value>(&buf[1..]) {
                    hub.provider_message(&v);
                }
            }
            TYPE_FRAME => {
                if let Some(f) = parse_frame(&buf[1..]) {
                    hub.frame(f);
                }
            }
            _ => {}
        }
    }
    writer.abort();
    hub.provider_down();
    eprintln!("seahelm-gateway: screen: provider gone");
}

#[cfg(not(unix))]
pub fn spawn(_hub: Arc<ScreenHub>) -> anyhow::Result<()> {
    Ok(())
}

/// Whether a page connected from `peer` may open the screen: never over a
/// connection readable on the wire. Loopback is a TLS terminator on this Mac
/// (cloudflared, `tailscale serve`) or a browser on it; Tailscale addresses
/// ride WireGuard.
pub fn peer_allowed(peer: std::net::IpAddr) -> bool {
    use std::net::IpAddr;
    if peer.is_loopback() {
        return true;
    }
    match peer {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            // 100.64.0.0/10
            o[0] == 100 && (o[1] & 0xC0) == 64
        }
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return peer_allowed(IpAddr::V4(v4));
            }
            let s = v6.segments();
            // fd7a:115c:a1e0::/48
            s[0] == 0xfd7a && s[1] == 0x115c && s[2] == 0xa1e0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plaintext_peers_are_refused() {
        let ok = |s: &str| peer_allowed(s.parse().unwrap());
        assert!(ok("127.0.0.1") && ok("::1"));
        assert!(ok("100.64.0.1") && ok("100.127.255.254") && ok("100.101.102.103"));
        assert!(ok("fd7a:115c:a1e0::1") && ok("::ffff:100.100.1.1"));
        assert!(!ok("100.128.0.1") && !ok("100.63.255.255"));
        assert!(!ok("192.168.1.20") && !ok("10.0.0.2") && !ok("::ffff:192.168.1.2") && !ok("fe80::1"));
    }

    #[test]
    fn frames_round_trip() {
        let f = parse_frame(&[CODEC_JPEG, 1, 0x07, 0x80, 0x04, 0x38, 0xff, 0xd8]).unwrap();
        assert_eq!((f.codec, f.key, f.width, f.height, f.data.as_slice()), (CODEC_JPEG, true, 1920, 1080, &[0xff, 0xd8][..]));
        assert_eq!(encode_for_page(&f), vec![1, 1, 3, CODEC_JPEG, 0x07, 0x80, 0x04, 0x38, 0xff, 0xd8]);
        assert!(parse_frame(&[1, 0, 0]).is_none());
        let j = encode_json(&json!({"a": 1}));
        assert_eq!(&j[..5], &[0, 0, 0, 8, TYPE_JSON]);
    }

    #[test]
    fn the_bitrate_follows_the_link() {
        use std::time::{Duration, Instant};
        let t0 = Instant::now();
        let at = |ms: u64| t0 + Duration::from_millis(ms);
        let mut a = Adapt::new(Some(4000), t0);
        // One skip is noise; and not within DROP_GAP of the start.
        assert_eq!(a.skipped(at(500)), None);
        assert_eq!(a.skipped(at(900)), None);
        assert_eq!(a.skipped(at(2100)), Some(2800));
        // Skips right after a drop wait for the next window.
        assert_eq!(a.skipped(at(2200)), None);
        assert_eq!(a.skipped(at(4300)), Some(1960));
        // Not raised while skips are recent, then a quarter at a time.
        assert_eq!(a.delivered(at(9000)), None);
        assert_eq!(a.delivered(at(14_400)), Some(2450));
        assert_eq!(a.delivered(at(15_000)), None);
        assert_eq!(a.delivered(at(24_500)), Some(3062));
        assert_eq!(a.delivered(at(34_600)), Some(3827));
        assert_eq!(a.delivered(at(44_700)), Some(4000));
        assert_eq!(a.delivered(at(60_000)), None);
        // Never below the floor.
        let mut low = Adapt::new(Some(300), t0);
        assert_eq!((low.skipped(at(3000)), low.skipped(at(3100))), (None, None));
        a.ask(1000, at(70_000));
        assert_eq!(a.kbps(), 1000);
    }

    #[tokio::test]
    async fn displays_and_the_clipboard_reach_the_pages() {
        let hub = ScreenHub::new();
        let (tx, mut rx) = mpsc::unbounded_channel();
        assert!(hub.provider_up(tx));
        let _ = rx.recv().await;
        let (_a, arx) = hub.open("phone", &Ask::default()).unwrap();
        let _ = (rx.recv().await, rx.recv().await);
        hub.provider_message(&json!({"type": "displays", "list": [{"id": 1}, {"id": 7}], "current": 1}));
        hub.provider_message(&json!({"type": "displays", "list": [{"id": 1}, {"id": 7}], "current": 1}));
        assert_eq!(arx.borrow().displays_seq, 1, "an unchanged list is not news");
        hub.choose_display(Some(7));
        assert_eq!(rx.recv().await.unwrap()["display"], 7);
        hub.provider_message(&json!({"type": "clipboard", "text": "hi"}));
        assert_eq!(arx.borrow().clipboard.as_deref().map(String::as_str), Some("hi"));
        hub.provider_message(&json!({"type": "clipboard", "text": "hi"}));
        hub.provider_message(&json!({"type": "clipboard", "text": "x".repeat(MAX_CLIPBOARD + 1)}));
        assert_eq!(arx.borrow().clipboard_seq, 1, "too long: dropped");
    }

    #[tokio::test]
    async fn viewers_tune_the_provider_and_leave_cleanly() {
        let hub = ScreenHub::new();
        assert!(hub.open("x", &Ask::default()).is_err());
        let (tx, mut rx) = mpsc::unbounded_channel();
        assert!(hub.provider_up(tx));
        let (tx2, _rx2) = mpsc::unbounded_channel();
        assert!(!hub.provider_up(tx2));
        assert_eq!(rx.recv().await.unwrap()["fps"], 0);

        let h264 = Some(vec!["h264".to_string(), "jpeg".to_string()]);
        let (a, arx) = hub.open("phone", &Ask { fps: Some(3), max_short: Some(800), kbps: Some(1500), codecs: h264.clone() }).unwrap();
        let w = rx.recv().await.unwrap();
        assert_eq!((w["fps"].as_u64(), w["max_short"].as_u64(), w["codec"].as_str()), (Some(3), Some(800), Some("h264")));
        assert_eq!(rx.recv().await.unwrap()["type"], "key_frame");
        let (b, _brx) = hub.open("pad", &Ask { fps: Some(10), max_short: Some(1200), kbps: None, codecs: None }).unwrap();
        let w = rx.recv().await.unwrap();
        assert_eq!((w["fps"].as_u64(), w["viewers"].as_array().map(Vec::len)), (Some(10), Some(2)));
        // A JPEG-only page brings everyone down to JPEG; the thinnest link sets the bitrate.
        assert_eq!((w["codec"].as_str(), w["kbps"].as_u64()), (Some("jpeg"), Some(1500)));
        // Within KEY_FRAME_EVERY of the last request: not asked again.
        assert!(rx.try_recv().is_err());

        hub.frame(Frame { codec: CODEC_JPEG, key: true, width: 2, height: 2, data: vec![1] });
        assert_eq!(arx.borrow().seq, 1);

        drop(b);
        let w = rx.recv().await.unwrap();
        assert_eq!((w["fps"].as_u64(), w["codec"].as_str()), (Some(3), Some("h264")));
        let epoch = a.epoch;
        hub.provider_message(&json!({"type": "stop"}));
        assert!(arx.borrow().epoch > epoch && arx.borrow().frame.is_none());
        assert_eq!(rx.recv().await.unwrap()["fps"], 0);
        drop(a);
        hub.provider_down();
        assert!(!hub.provider_connected());
    }
}
