# seahelm-web — Host Gateway browser client

The browser client for Seahelm (plain static page + xterm.js). **In production it talks to the Host Gateway embedded in the Mac app over WSS.**
Once paired it connects straight to `wss://…/ws` and speaks JSON-RPC request/reply plus VT notifies; terminal bytes no longer travel over MQTT.

> **Not an Artifact**: a Claude Artifact's CSP forbids connecting to an external WS, so this has to be opened as an ordinary static page in a browser.

## Production use (Gateway-first)

1. Enable the Host Gateway on the Mac (Seahelm Settings → Host Gateway / Browser access).
2. Open the Gateway page in a browser (e.g. `http://<Mac Tailscale IP>:2783/`, or localhost) — **http or https, either works**.
3. Type the **pairing code** shown in Settings → Pair and connect. The code does not expire; it defaults to 8 random digits, and **Set code…** in Settings lets you choose your own 8–16 digit one.
4. On connect the page runs `session.snapshot` → First Mate paints the pane list → tap a row to open it.
5. The browser remembers the token and reconnects by itself next time. Refreshing the pairing code does not evict a browser that is already paired; **Revoke all remotes** does.

### Text mode (the phone default)

A narrow screen (≤760px) opens on the **Timeline** (MessageStream) and never calls `pane.vt_open`:

- the server pushes `pane.message` (user / tool / assistant / status / decision / notice), replaying each pane's last 80 on connect
- scrolling up loads earlier messages (`message.history`, paged by `before_seq`, 50 at a time)
- the timeline is stored at `~/.config/seahelm/message-stream/<pane_session_key>.jsonl`, about 2000 rows kept per pane; it survives an app restart and is deleted when the pane closes
- assistant replies render as markdown (`markdown.js` — escape first, then format; only http/https links are allowed through)
- the head bar toggles **Timeline / Terminal**; only Terminal takes the VT path
- in timeline mode the terminal key bar folds away and only **Interrupt** is left: Esc for an agent, Ctrl+C for a shell task
- the composer at the bottom sends `pane.send_text`
- the preference lives in `localStorage seahelm_surface_mode`

A wide window still defaults to VT and can be switched to the timeline by hand. Design: `docs/superpowers/specs/2026-09-17-message-stream-design.md`.

Transport: `/ws` on the page's own origin — the WebSocket the Host Gateway serves.

Gateway handshake:

1. first visit: `auth` → `{code}` → returns `{ok, mac_id, token, vt_binary, vt_deflate}`
2. return visit: `auth` → `{mac_id, token}` (from localStorage)
3. `session.snapshot` → fills First Mate
4. pick a pane → `pane.vt_open`; the server pushes binary VT frames (or legacy JSON)
5. keystrokes → `pane.send_keys` `{pane_session_key, b64}`

Wire format:

```
request:  {"id","method","params"}
reply:    {"id","result"} or {"id","error"}
push:     {"type":"notify","method","params"}
```

## Layout of the source

| File | What it does |
|---|---|
| `index.html` | the client itself: First Mate on the left, timeline / VT terminal in the middle, message log on the right |
| `xterm.js` / `xterm.css` | vendored xterm.js 5.5.0 |
| `xterm-addon-webgl.js` | vendored WebGL renderer — loaded on first terminal open, not at page load |
| `touch-scroll.js` | vertical touch drag → terminal wheel, so a phone can scroll back |
| `vt-frame.js` | binary VT frame codec, shared by `index.html` and `bench.html`, format matching `HostGatewayVTFrame.swift` |
| `vt-apply.js` | serializes VT frame writes; waits for `term.write` before applying the next frame |
| `term-focus.js` | a click on the chrome does not steal the terminal caret — real input fields excepted |
| `composer-keys.js` | what Enter / Esc mean in the timeline composer; hands both back to an IME while it is composing |
| `devbroker/` | dependency-free node unit tests for the modules above, plus the result collector for `bench.html` |

## The interface

- **Left column = First Mate**, ported from the Mac dashboard's "Group by Sailor" mode.
- **Middle = terminal**, picking a pane opens its VT.
- **Right column = message log**, for development; can be hidden.

### Responsive

| Width | Layout |
|---|---|
| > 1100px | three columns, log column toggled by hand |
| ≤ 1100px | log column hidden automatically |
| ≤ 760px | one column, First Mate in a drawer (☰) |

The terminal fits itself to the width, down to a 9px floor; a one-finger vertical drag scrolls back on a phone (a horizontal drag is left alone); the **↓ Latest** button appears in the lower right while you are reading back.

### VT subscription mode

The **Single / Mirror** badge in the terminal head bar switches the VT attach policy (`localStorage seahelm_vt_mode`, default **`single`**):

| Mode | Behaviour |
|---|---|
| **Single** (default) | attach only the focused pane — kind to a weak link and a small screen; with several panes you switch with the chips in the head bar |
| **Mirror** | one VT stream per pane, rendered together in the Mac's split layout |

A narrow window is forced to single anyway (a mirror preference is ignored when `layoutFitsMirror` is not satisfied).

## Behaviour on a weak link

| Capability | What it does |
|---|---|
| **Static assets** | the Gateway gzips js/css/html; anything with `?v=` is cacheable long-term; HTTP keep-alive fetches several files over one connection |
| **Deferred WebGL** | `xterm-addon-webgl.js` loads after the first terminal opens, not before |
| **Single by default** | see "VT subscription mode" above — only the focused pane is subscribed; mirror is opt-in |
| **Backpressure** | the Mac's VT send queue is bounded; under backlog it drops old `vt.data` and re-snapshots, so the screen may jump briefly |
| **Browser frame drops** | when the decompress/write backlog passes its depth limit, intermediate `vt.data` is dropped |
| **binary keys** | once `auth` negotiates `keys_binary`, keystrokes go as binary frames (no JSON/base64); an older Mac still gets `pane.send_keys` |

## VT terminal

The Mac serves a faithful PTY stream through **`zmx attach`**; the browser renders it with xterm.js.
Gateway notifies carry `{b64, cols?, rows?}`, decoded by `handleVT()`.

Commands (Gateway JSON-RPC):

| method | What it does |
|---|---|
| `pane.vt_open` | attach; `vt.snapshot` first, `vt.data` after |
| `pane.vt_keepalive` | 20s heartbeat |
| `pane.vt_close` | detach this client |
| `pane.send_keys` | `{b64}` UTF-8 key sequence; can go as binary frames once `keys_binary` is negotiated |

## Tests

No `npm install` needed — run them straight from `clients/seahelm-web`:

```bash
for t in devbroker/*-test.js; do node "$t" || break; done
```

## Related documents

- `docs/superpowers/specs/2026-08-10-web-host-gateway-design.md` — Gateway design
- `docs/remote-clients-design.md` — the MQTT protocol (Watch/ESP32; the web client uses the Gateway in production)
