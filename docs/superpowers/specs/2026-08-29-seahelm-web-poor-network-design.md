# seahelm-web poor-network design

> **Status:** Accepted for planning (2026-08-29)  
> **Scope:** Host Gateway static hosting + VT send path + seahelm-web client  
> **Out of scope:** Second WebSocket, screen-sync protocol, changing zmx/Ghostty fidelity, mandatory single-pane without a UI toggle

## Problem

Under poor networks (high latency, DERP relay, lossy links), seahelm-web feels bad in several ways at once:

1. **Page load** — the Gateway serves ~720KB+ of JS uncompressed, with `Connection: close` and `Cache-Control: no-cache`, so the shell itself is hard to open.
2. **VT backlog** — Mac reads PTY at full rate and queues outbound frames with no backpressure; the browser falls further behind.
3. **Input lag** — `pane.send_keys` (JSON + base64) shares one WebSocket with VT floods and can be starved.
4. **Multi-pane cost** — mirror mode opens one `zmx attach` per leaf (`N` full streams).

Already in place (keep): binary VT frames, per-frame deflate, ~16ms adaptive coalesce, browser 10ms key batching, shallow scrollback under multi-pane, narrow-layout single attach.

## Goals

| Goal | Success signal |
|---|---|
| Page opens on weak links | gzip for text assets; keep-alive; cacheable JS/CSS; defer WebGL / ghostty |
| Backlog does not snowball | bounded send queue; drop-old + resync instead of unbounded pending |
| Typing stays usable | high-priority outbound control; optional binary keys |
| User controls bandwidth | UI toggle: single-pane vs mirror; default **single** |

## Non-goals (this iteration)

- Dual WebSocket / separate VT socket
- Adaptive “video-like” terminal quality or non-PTY screen protocol
- Preserving browser scrollback across pane switches (same as today’s mobile single mode)
- Forcing default single-pane with no override
- Brotli (gzip is enough for v1)

---

## 1. Static assets

### Current behavior

`HostGatewayStaticFiles` returns raw file bytes, `Connection: close`, and site-wide `Cache-Control: no-cache`. Typical first paint pulls `xterm.js` (~478KB) + `xterm-addon-webgl.js` (~242KB); `vendor/ghostty-web.js` (~666KB) only when renderer=ghostty.

### Design

**gzip**

- For `js` / `css` / `html` / `svg` / `json` / `mjs`: if `Accept-Encoding` includes `gzip`, respond with `Content-Encoding: gzip` and compressed body.
- Cache `(path, mtime) → gzip bytes` in memory; invalidate when mtime changes.
- On compress failure, fall back to identity encoding.

**caching**

- `index.html`: keep `Cache-Control: no-cache` (or very short max-age) so the shell stays fresh.
- Fingerprinted or version-queried static assets (`?v=` or build fingerprint): `Cache-Control: public, max-age=31536000, immutable`.
- Other static assets: at least `max-age=86400` plus `ETag` / `Last-Modified` and `304` support.

**keep-alive**

- Static HTTP/1.1 responses use `Connection: keep-alive` so one TCP/TLS (or tunnel) connection can fetch multiple assets.
- Adjust `HostGatewayServer` static request handling if today’s path closes after each response.

**deferred scripts (client)**

- Critical path: `e2ee.js` + `xterm.js` only.
- Load `xterm-addon-webgl.js` dynamically after the first terminal `open`; on failure keep DOM renderer.
- `ghostty-web`: only on `?renderer=ghostty` / explicit toggle (no default request).
- Exclude `bench.html` / `bench-corpus.js` from the app bundle (`project.yml` rsync excludes).

### Files

- `Sources/Core/HostGatewayStaticFiles.swift`
- `Sources/Core/HostGatewayServer.swift` (keep-alive / multi-request)
- `clients/seahelm-web/index.html`
- `project.yml` (bundle excludes)

---

## 2. Single-pane / mirror toggle

### UI

- Control next to the terminal header badges (same tier as renderer badge): **单屏** / **镜像**.
- Persist in `localStorage` (`seahelm_vt_mode = single | mirror`).
- On narrow layouts where `layoutFitsMirror` is false, force single; disable or hide mirror.

### Behavior

| Mode | Attach | UI |
|---|---|---|
| **single** | Only `vt_open` the focused pane; on switch, `vt_close` old then open new | One terminal + pane strip (`mountSinglePane`) |
| **mirror** | When layout fits, `vt_open` every leaf (current mirror) | Nested flex tree |

- Toggling remounts immediately (`unmountPanes` → `mountPanes`). Browser scrollback for disposed terminals is lost (acceptable; matches mobile today).
- **Default: `single`** (poor-network friendly). User choice remembered.
- No new Mac RPCs.

### History

- Mac/zmx session and agent processes are untouched.
- Re-open uses attach **snapshot** (current screen fidelity), not deep browser scrollback.
- “Keep xterm alive while pausing the stream” is explicitly out of scope for this design.

### Files

- `clients/seahelm-web/index.html` (and README note)

---

## 3. Send backpressure + drop-old / resync

### Problem

PTY is read at full speed; `NWConnection.send` completions are effectively ignored. Under a slow tunnel, pending VT grows and the UI falls behind.

### Design

Per Gateway **session** (and tracked per pane):

1. **Bounded outbound VT budget**  
   - Example caps (tune in implementation, document constants): total pending VT ≤ **256KB**, or per-pane ≤ **128KB**.  
   - Count encoded-or-estimated payload consistently.

2. **On overflow: drop old, keep latest**  
   - Discard older `vt.data` for that pane from the low-priority queue.  
   - Set `needsResync[pane] = true`.  
   - Never drop high-priority control/RPC frames.

3. **Resync**  
   - When marked, emit a `vt.snapshot` as soon as practical so the client `term.reset()` and resumes from a clean screen.  
   - If a full screen buffer is not available, a minimal/empty snapshot that still triggers client reset is acceptable; TUIs repaint; shell may briefly lack scrollback.  
   - Optional explicit `vt.resync` notify is allowed but not required if snapshot already resets.  
   - **Rate-limit** forced resync per pane (e.g. ≥1s) to avoid snapshot storms.

4. **Light read-side adaptation**  
   - While `needsResync` or the queue stays full: increase coalesce window (e.g. 16ms → 80ms) and allow larger chunks for that pane.  
   - Do **not** tear down `zmx attach` for backpressure.

5. **Browser assist**  
   - If per-pane `vtWriteChains` depth exceeds N, drop intermediate `vt.data`, keep newest; honor snapshot reset.

### Non-goals here

- Full RTT-based ABR controller  
- Stopping the PTY reader / applying backpressure into zmx

### Files

- `Sources/Core/HostGatewaySession.swift` (queues, drain, caps)
- `Sources/Core/HostGatewayServer.swift` (send completion → drain)
- `Sources/Core/ZmxVTAttachManager.swift` (optional coalesce knobs)
- `clients/seahelm-web/index.html` (write-chain drop)
- Tests: new session queue tests; existing Host Gateway tests must still pass

---

## 4. Control priority + binary keys

### Outbound priority (same WebSocket)

Two egress queues per session:

| Priority | Traffic |
|---|---|
| **High** | RPC replies, auth-related, `pane.event`, errors |
| **Low** | `vt.data` / `vt.snapshot` / binary VT |

Drain rule: **always empty high before low**. Low still obeys §3 byte budgets.

No second socket in this design.

### Binary `send_keys` (negotiated)

- Client may send `keys_binary: true` on `auth` (alongside existing `vt_binary` / `vt_deflate`).
- Binary inbound frame (symmetric spirit to VT frames), e.g.  
  `u8 version | u8 kind=keys | u8 keyLen | key… | raw UTF-8 bytes`  
  (no JSON envelope, no base64).
- Server routes to existing `sendKeys`; clients without negotiation keep JSON `pane.send_keys`.
- Keep browser 10ms key coalescing.
- Client must not let VT inflate/write Promise chains block `ws.send` for keys.

Echo still depends on VT downlink; §3 prevents multi-second backlog from owning the pipe.

### Files

- `Sources/Core/HostGatewaySession.swift` / server inbound binary demux
- Shared frame helper (extend `HostGatewayVTFrame` or sibling `HostGatewayKeyFrame`)
- `clients/seahelm-web/index.html`
- Unit tests for encode/decode round-trip + auth negotiation

---

## Error handling / degradation

| Failure | Fallback |
|---|---|
| gzip fails | identity body |
| WebGL dynamic import fails | DOM renderer |
| `keys_binary` unsupported | JSON `send_keys` |
| Resync thrash | per-pane minimum interval |
| Queue drops | debug counters only (no user toast in v1) |

---

## Testing

| Layer | Coverage |
|---|---|
| Unit | StaticFiles: gzip headers, Accept-Encoding, ETag/304, Cache-Control split html vs assets |
| Unit | VT queue: over-budget drop-old, needsResync, high priority not starved |
| Unit | Binary keys round-trip + negotiation |
| Manual / light client | Mode toggle opens/closes the expected pane set |
| Regression | Existing `HostGateway*Tests`, `VTPipelineBenchmarks` |

---

## Implementation order

1. Static gzip + cache + keep-alive + deferred WebGL + exclude bench from bundle  
2. Single / mirror UI toggle (default single)  
3. Server egress priority + bounded queue drop-old / resync (+ light client write-chain drop)  
4. Binary keys negotiation  

---

## Open parameters (fix at implement time, not product unknowns)

- Exact pending byte caps (256KB / 128KB starting points)
- Resync minimum interval (~1s starting point)
- Client write-chain drop depth `N`
- Whether versioned URLs use existing `?v=` stamps or content hashes

## References

- `docs/superpowers/specs/2026-08-10-web-host-gateway-design.md`
- `Sources/Core/HostGatewayStaticFiles.swift`, `HostGatewaySession.swift`, `HostGatewayVTFrame.swift`, `ZmxVTAttachManager.swift`
- `clients/seahelm-web/index.html`
