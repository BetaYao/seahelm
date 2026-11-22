# Remote screen: see and control the whole Mac from seahelm-web

Status: phase 1 (JPEG) prototype built 2026-11-22; phases 2–3 are design only.
Phase 1 as built: `Sources/Screen/` (`ScreenShareService`: stills through
`SCScreenshotManager`, JPEG through ImageIO, a menu bar SCREEN item with Stop;
`ScreenInputInjector`), `seahelmd/crates/gateway/src/screen.rs` (`screen.sock`,
`ScreenHub`, the connection rule) and `screen.*` in `web/session.rs`,
`clients/seahelm-web/screen-view.js`. The island badge is an `IslandWarning`
(`SCREEN`), outranking the others.

Phase 2, first part (H.264 over `/ws`), built 2026-11-22: `ScreenVideoStream`
(SCStream NV12 → `H264Encoder`, VideoToolbox High profile, real time, no
reordering, Annex B), `watch.codec` (`h264` when every viewer listed it in
`screen.open {codecs}`, else `jpeg`), `watch.kbps` (the lowest asked),
`key_frame` requests (on open, on a skipped frame, on the page's
`screen.key_frame`, at most every 700 ms), and WebCodecs decoding in the page
(JPEG outside a secure context or without a decoder). Measured on the way: a
VideoToolbox SPS carries no VUI `bitstream_restriction`, and Chrome's decoder
then held every frame until flushed — a still screen never showed. The
encoder now rewrites each SPS with `max_num_reorder_frames = 0`
(`SPSRewriter`, as WebRTC's `SpsVuiRewriter` does).

Phase 2, second part, built 2026-11-22:
- **Display picker:** the app reports `displays {list, current}` on connect, on
  a screen change and when the captured display changes; pages get it as
  `screen.info {displays, display}` and pick with `screen.display {id}`, which
  the gateway passes on as `watch.display`. One picture is shared, so the last
  pick wins; it resets to the main display when the last viewer leaves.
- **Clipboard:** while anyone watches, the app sends the clipboard's text when
  `changeCount` moves (polled every 0.5 s), except what password managers mark
  `org.nspasteboard.ConcealedType` / `TransientType`; pages get
  `screen.info {clipboard}`. A page's `screen.clipboard {text}` goes onto the
  Mac's clipboard (and is not echoed back). 256 KB at most, both ways. The page
  copies the Mac's text through a tap (browsers allow clipboard writes only
  from a gesture), and "Put on Mac + ⌘V" also pastes it.
- **Adaptive bitrate:** per page, in the gateway (`screen::Adapt`). A skipped
  frame means the page's socket was still busy with older ones. Two skips
  within 3 s, at least 2 s after the last change, lower that page's kbps by
  30%, down to 300. Ten calm seconds raise it by a quarter, up to what the page
  asked for. The stream's rate is the lowest among the viewers, as before.
  The page shows the cap in its status line (`screen.info {kbps}`).

Still to do: the cursor drawn by the page (`showsCursor` stays on, which is
enough at H.264 frame rates), and the keyboard raised on focus. iOS raises the
keyboard only from a user gesture, so the app's focus report could at most
highlight the keyboard button.

## Goal

From a phone, see the Mac's whole desktop and drive it: landscape and full
width, touch as the mouse (click, right-click, drag, scroll), pinch to zoom the
picture, and the phone's real keyboard on demand. Not one pane projected to the
phone — seahelm-web already does that — but the machine.

Other tools stop short of this: Claude Code's Remote Control is per session,
Cursor Mobile per agent, and herdr's phone client promises never to touch the
computer's layout. Alma ([alma.now](https://alma.now/)) is the one that ships
full-screen control; its design is summarised below because this one borrows
from it.

Non-goals for now: audio, file transfer, unlocking the Mac with its login
password from the phone, controlling a Linux or Windows host, and viewing one
Mac from another.

## Prior art: how Alma does it

Read from Alma 0.4.972's macOS bundle (not run):

- **Capture and encode** in its native Go app: ScreenCaptureKit (`SCStream`,
  frame interval, queue depth, cursor on/off, scale-to-fit), VideoToolbox
  H.264 / H.265 (real time, no frame reordering, set bitrate, frame rate and
  key-frame interval, optional HEVC 4:4:4 for sharper text), Opus audio.
- **Two transports.** A session starts as JPEG screenshots over the viewer's
  WebSocket (frames skipped while the socket's send buffer is backed up), then
  upgrades to WebRTC (Pion) when the phone sends `rtc_start {view, quality:
  {fps 1–120, kbps 300–50000, maxShort}, relayOnly, codecs}`. SDP and ICE go
  over the same WebSocket; `rtc_quality` retunes mid-stream. Relay-only mode
  requires a TURN server; with none configured only STUN is used.
- **Input** arrives as JSON with coordinates normalised to 0–1: `pointer
  {move|down|up|click|double|right|middle}`, `scroll {dx, dy}`, `scroll_to`,
  `key {"cmd+v"}`, `text`, `clipboard {text, paste}`. A separate Swift helper
  (the same one its computer-use feature uses) posts the CGEvents, takes
  window/display shots and locks/unlocks the screen.
- **Feedback that makes it feel native:** the cursor's position and shape are
  sent separately and drawn by the phone; `focus {editable, secure}` tells the
  phone when to raise its keyboard; the clipboard is polled both ways.
- **Its WebSocket** runs over LAN when it can, else through its E2E-encrypted
  relay ([alma-relay](https://github.com/yetone/alma-relay): authenticated
  ECDH + AES-256-GCM keyed from the pairing code), preferring a Tailscale path
  when present. WebRTC media goes peer to peer or through TURN.

## Constraints from seahelm

- seahelm-web reaches the Mac through seahelm-gateway's `/ws`, usually via a
  Cloudflare Tunnel (`gw.seahelm.dev`). The tunnel carries HTTP and WebSocket
  only, **not UDP**, so WebRTC media cannot use the path everything else uses.
- macOS grants Screen Recording and Accessibility per app. `seahelm.app` is a
  signed bundle the user recognises in System Settings; `seahelm-gateway` is a
  command-line binary started detached by `seahelm-gateway ensure`, whose
  permission attribution would be unclear.
- The gateway already authenticates every page (`Who::Device` from a paired
  device or a Telegram Mini App sign-in, `Who::Share` for a share link) and
  already sends binary frames (`web/frames.rs`: VT kind 1 data, kind 2
  snapshot).
- The app already manages the gateway over `gateway.sock` (newline-delimited
  JSON-RPC: `GatewayLink`, `GatewayClient`, `GatewayEventStream`).
- The gateway's web server listens on `0.0.0.0` (`web/mod.rs`), so besides
  the tunnel it is already reachable at the Mac's LAN address and its
  Tailscale address, over plain HTTP.
- Browsers expose WebCodecs (`VideoDecoder`) and `navigator.clipboard` only in
  a **secure context**: HTTPS or localhost. A page opened at
  `http://192.168.x.x:PORT` or `http://100.x.y.z:PORT` gets neither, so it can
  do JPEG only, and everything on that connection (picture, typed text) is in
  the clear.

## Network paths

| Path | URL | Encrypted | Secure context | Latency |
|---|---|---|---|---|
| Tailscale + `tailscale serve` (**recommended**) | `https://<mac>.<tailnet>.ts.net` | TLS + WireGuard | yes | LAN direct at home; P2P (or DERP relay) away |
| Cloudflare Tunnel (fallback) | `https://gw.seahelm.dev` | TLS to Cloudflare | yes | every frame via Cloudflare |
| Tailscale IP, plain HTTP | `http://100.x.y.z:PORT` | WireGuard | no | as Tailscale |
| LAN IP, plain HTTP | `http://192.168.x.x:PORT` | **no** | no | LAN |

Tailscale picks the LAN path by itself when phone and Mac share a network
(`tailscale ping <mac>` reports `via 192.168.x.x:41641`, not `via DERP`), so
one URL serves at home and away. `tailscale serve --bg <gateway port>` after
enabling HTTPS certificates in the tailnet's admin console gives that URL a
valid certificate; the proxy runs on the Mac and reaches the gateway over
loopback. On this path tier 2 (H.264 over `/ws`) is already low latency, so
tier 3 (WebRTC) buys nothing.

The recommended setup is therefore Tailscale with `tailscale serve`;
`gw.seahelm.dev` is for phones without Tailscale.

## Design

```
seahelm.app ──encoded frames──▶ seahelm-gateway ──/ws binary frame kind 3──▶ seahelm-web
     ▲            screen.sock                                                  │
     └──────────── pointer / scroll / key / text / clipboard ◀─────────────────┘
```

Capture and input live in the **app**, which holds the permissions. The
**gateway** only authorises, fans out and drops frames. The **page** draws and
turns touches into input.

### App: `Sources/Screen/`

- `ScreenCaptureSource` — ScreenCaptureKit stream of one display (the main one
  to start with), scaled so the frame's short side is at most the size the page
  asked for. Runs only while at least one page is watching; stops when the
  gateway says the last one left.
- `ScreenEncoder` — phase 1 JPEG (ImageIO), phase 2 H.264 through
  `VTCompressionSession` (real time, no B-frames, Baseline or Main profile,
  key frame on demand and every few seconds).
- `ScreenInputInjector` — maps normalised coordinates onto the display's
  global frame and posts `CGEvent`s: move, down/up, click, double, right,
  scroll (pixel deltas), key chords (spelled as `KeyChord` already spells
  them, e.g. `cmd+shift+t`) and text (`CGEventKeyboardSetUnicodeString`).
- `ScreenCursorWatcher` (phase 2) — cursor position and shape (`NSCursor`
  image, hot spot), sent apart from the video so the stream can leave the
  cursor out.
- `ScreenFocusWatcher` (phase 2) — the focused element's role through the
  Accessibility API: editable or not, secure or not.
- Permissions: Screen Recording and Accessibility, asked for the first time the
  user turns the feature on in Settings, never at launch.

### App ↔ gateway: `screen.sock`

Frames are large binary blobs and do not belong in `gateway.sock`'s JSON lines.
A second socket, `~/.config/seahelm/gateway/screen.sock` (0600, same peer check
as `gateway.sock`):

- The app connects and identifies itself (the only allowed provider; a second
  connection is refused while one is live).
- App → gateway: length-prefixed frames `[u32 len][u8 type][payload]`, with
  type `frame` (codec, width, height, key-frame flag, timestamp, bytes),
  `cursor`, `focus`, `clipboard`, `displays`.
- Gateway → app: `watch {max_short, fps, kbps, codec}` (the strictest of what
  the watching pages asked for; `fps 0` = stop), `key_frame` (a page joined or
  lost frames), and the input messages below, verbatim.

### Gateway

- **Wire** (`web/frames.rs`): binary kind 3, screen frame:
  `u8 version=1, u8 flags (bit 0 key frame), u8 kind=3, u8 codec (1 JPEG,
  2 H.264 Annex B), u16 BE width, u16 BE height, u32 BE timestamp ms, payload`.
  Cursor, focus, clipboard and display lists go as JSON notifies
  (`screen.cursor`, `screen.focus`, `screen.clipboard`, `screen.displays`).
- **Methods** (`web/session.rs`): `screen.open {max_short, fps, kbps, codecs}`,
  `screen.quality`, `screen.close`, `screen.pointer {action, x, y}`,
  `screen.scroll {x, y, dx, dy}`, `screen.key {key}`, `screen.text {text}`,
  `screen.clipboard {text, paste}`, `screen.display {id}`.
- **Who may use it:** a `Who::Device` from pairing only. Share links are
  refused, and so, until decided otherwise, are devices issued by a Telegram
  Mini App sign-in (a Telegram account is a weaker credential than a paired
  device).
- **Which connections may use it:** `screen.open` is refused on a connection
  that can be read on the wire. Allowed are connections whose peer is
  loopback (a TLS terminator on the Mac: cloudflared for the tunnel,
  `tailscale serve`) and peers in Tailscale's `100.64.0.0/10` or
  `fd7a:115c:a1e0::/48` (WireGuard-encrypted even over plain HTTP, though
  without a secure context the page is limited to JPEG). A LAN or other
  address is refused with a reason the page shows, naming the HTTPS URL to
  use instead. The peer address comes from axum's `ConnectInfo`, never from
  forwarded headers. The feature is off unless Settings ▸ Pairing ▸ "Allow controlling
  this Mac" is on; turning it off ends every running screen session.
- **Back-pressure:** each page keeps at most one undelivered frame. A newer
  frame replaces it, as a slow VT client is repainted rather than queued.
  With H.264 a dropped frame breaks the chain: the page is marked as needing a
  key frame and gets nothing until the next one, and the gateway asks the app
  for one (`key_frame`).
- **Audit:** each session's start, end, device label and input count go to the
  gateway's log; the app is told who is watching.

### seahelm-web: `screen-view.js`

- A third view beside Timeline and Terminal, opened from the fleet list's
  title bar. It belongs to the machine, not to a pane.
- **Picture:** a `<canvas>`. JPEG frames through `createImageBitmap`; H.264
  through WebCodecs `VideoDecoder` (hardware decode; iOS Safari 16.4+). Asks
  for JPEG when `window.isSecureContext` is false (and says why: open the
  HTTPS address for smooth video and clipboard), or when `VideoDecoder` is
  missing or rejects the stream. Clipboard sync is offered only in a secure
  context.
- **Gestures** (building on `touch-scroll.js`):
  - tap = click, double tap = double click, long press = right click;
  - one-finger drag = scroll; press and hold, then drag = mouse drag;
  - pinch = zoom the picture locally (not sent to the Mac), pan when zoomed.

  A "trackpad" mode (relative cursor, tap where the cursor is) is worth adding
  for precise targets on a small screen.
- **Cursor:** drawn by the page from `screen.cursor` (phase 2).
- **Keyboard:** a hidden input that raises the system keyboard, opened by a
  button and automatically on `screen.focus {editable: true}`; typed text goes
  as `screen.text`, Backspace and Return as `screen.key`. A key strip above
  it: esc, tab, arrows, and sticky ⌘ ⌥ ⌃ ⇧.
- **Landscape:** in landscape the view hides all page chrome. iPhone Safari
  offers no Fullscreen API for a canvas and no orientation lock, so true full
  screen needs the page opened from the home screen (standalone).
- **Quality:** the page asks for `max_short` from its own pixel size, lowers
  fps/kbps when its decode queue grows, and sends `screen.close` when hidden
  (`visibilitychange`).

### Transport tiers

| Tier | Path | Works through the tunnel | Bandwidth | Weak spot |
|---|---|---|---|---|
| 1. JPEG over `/ws` | existing WebSocket | yes | high (whole frames) | low frame rate |
| 2. H.264 over `/ws` + WebCodecs | existing WebSocket | yes | low | TCP stalls on loss |
| 3. WebRTC (optional) | P2P / Tailscale / TURN | no, needs its own path | low | NAT traversal, TURN cost |

Tier 2 is seahelm's main target. It needs no NAT traversal and no TURN, it
rides the path the terminal already uses, and it is about as responsive as the
web terminal is today. Tier 3 is only worth it if tier 2 proves too laggy over
real mobile networks. Signalling for it would go over `/ws`; media would need
P2P, Tailscale or a TURN service (Cloudflare's or a self-hosted coturn).

### Safety

- Off by default; turned on only from the Mac.
- While anyone watches, the island shows a `SCREEN` badge (beside the
  existing `IslandWarning` badges) naming the device, with a one-click "Stop",
  which ends the session and revokes nothing else.
- Paired devices only; no share links; Telegram sign-in excluded for now.
- Never over a plaintext connection: loopback-terminated TLS or Tailscale
  only (see the gateway's connection rule).
- No unlocking the Mac by password from the phone. A locked Mac shows its lock
  screen and accepts no input, as macOS enforces anyway.
- Secure text fields: `focus.secure` is shown on the phone so the user knows
  the typed text is a password. Text is sent over the same TLS WebSocket as
  terminal keys, and the gateway does not log it.

## Phases

1. **JPEG prototype.** Main display only, 2–5 fps, tap, scroll, text, key
   strip, the Settings switch, the island badge, paired devices only, the
   connection rule. Proves
   permissions, `screen.sock`, the gateway path and the page end to end.
2. **H.264 over `/ws`.** VideoToolbox + WebCodecs, cursor drawn by the page,
   keyboard raised on focus, clipboard both ways, display picker, adaptive
   quality.
3. **Optional WebRTC.** Only if measurements over mobile networks call for it.

## Open questions

- Should Settings ▸ Pairing detect Tailscale (`tailscale status --json`:
  MagicDNS name, whether `serve` is set up for the gateway's port) and offer
  the `ts.net` URL and QR code in place of the tunnel's?

- Does the Telegram Mini App's web view (WKWebView on iOS, a WebView on
  Android) expose WebCodecs `VideoDecoder`? It only matters if Telegram
  devices are later allowed in.
- One screen session at a time, or several viewers sharing one stream (and
  whose quality wins)? The design above fans out one stream and encodes for
  the strictest viewer.
- Should a remote session wake the display and prevent sleep
  (`IOPMAssertion`) while it runs?
- Retina scaling: should the page see points or pixels when asking for
  `max_short`? Points keep frames small; pixels keep small text legible.
