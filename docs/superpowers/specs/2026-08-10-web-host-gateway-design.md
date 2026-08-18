# Web remote control via Host Gateway (design)

> **Status:** **P0 + same-origin hosting implemented** (2026-08-18). In-app Host Gateway (pair auth, ControlProtocol, `zmx attach` VT) is wired; `seahelm-web` defaults to Gateway WSS and is now **served by the Gateway itself** on the same port as `/ws` (#56). The browser client mirrors the desktop: live split layout via `layout.live`, the dashboard's own grouping via `fleet.groups` (#56, #58).  
> **P1 remaining:** rotate-key UI polish.  
> **Dropped from P1:** *Cloudflare Tunnel Settings UX*. The tunnel is deliberately **not** coupled to the app — an integration that started and stopped `cloudflared` with the Gateway was built and then removed, because a tunnel outliving the app leaves a public hostname resolving to a dead port, and one tied to the app makes seahelm responsible for a process it does not own. Run the tunnel however you like; the Gateway only serves its port.  
> **Goal:** Control a running Seahelm on your Mac from any public browser, with a real VT terminal (not status-only).  
> **Supersedes for the web path:** treating `clients/seahelm-web` + `devbroker` / `mock:zmx` / `live-bridge` as the production remote-control story; VT-over-MQTT for the browser.

Related docs (still valid for other clients):

- `docs/remote-clients-design.md` — MQTT trunk for Watch / ESP32 / status+short commands (web VT uses Host Gateway, not MQTT)  
- `clients/seahelm-web/README.md` — Gateway-first browser client; `devbroker` for local MQTT debug only  
- `docs/superpowers/plans/2026-08-10-web-host-gateway.md` — implementation plan + P0 checklist

---

## 0. Decisions locked in brainstorm

| Question | Choice |
|---|---|
| Product shape | **B — remote-desktop feel**: open a pane in the browser and get a real terminal |
| Reach | **Public browser** (hotel Wi‑Fi, no Tailscale/VPN required) |
| Auth | **Pairing** (`seahelm://pair?…`), not URL secrecy alone |
| Public entry | **Cloudflare Tunnel from the Mac** (not `gw.seahelm.dev` / VPS EMQX as the web primary path) |
| VT Mac source | **`zmx attach`** (not Ghostty feed; not `zmx tail`) |
| VT browser renderer | **xterm.js** |
| Pairing UI | **Reuse** Settings / `PairingPaneView` + `MqttCrypto` |

---

## 1. Boundaries

```
  Browser (seahelm-web)          Cloudflare Tunnel           Mac (Seahelm App)
  static page + xterm.js  ─────▶  public hostname  ─────▶  Host Gateway (in-process)
                                                            ├─ pairing auth
                                                            ├─ control: ControlProtocol
                                                            └─ data: zmx attach VT streams
```

**Hard rules**

1. **URL ≠ authorization.** Without the pairing root secret, the Gateway rejects all business traffic (no pane list, no VT, no keys).
2. **Web talks only to the Host Gateway** over WSS. Production web does not use MQTT, `live-bridge`, or `mock:zmx`.
3. **Status detection stays on the Mac** (`ShipLog` / detectors). The page displays and inputs only.
4. **MQTT / `MqttChannel`** may continue to serve Watch/ESP; it is **not** the web VT transport and must not block the Gateway path.
5. **Tunnel provides reachability only.** All auth and authorization live in the Gateway.

**Out of scope (this design)**

- VT bytes over MQTT for production web  
- Required self-hosted `clients/seahelm-stack` for web remote control  
- Sidecar `seahelmd` process  
- Ghostty `feed_data` / custom-io as the web renderer path  
- Short-code PAKE handshake for Watch (UI may remain; wiring stays Watch-phase)

---

## 2. Pairing and connection

### 2.1 User path

1. Install/login Cloudflare Tunnel once.  
2. Point the tunnel's ingress at the Gateway's local port. One rule covers both
   the page and the socket, since they share an origin:

   ```yaml
   ingress:
     - hostname: gw.example.dev
       service: http://127.0.0.1:2783
     - service: http_status:404
   ```  
3. Launch Seahelm → Gateway listens → tunnel publishes a public HTTPS/WSS origin.  
4. Settings → Pairing: scan QR or copy the long link.  
5. On another device, open the web UI (**served by the Gateway itself**, same origin as `/ws`) → paste pair link → connect.

> **Same-origin is a hard requirement, not a preference.** `SubtleCrypto` — which
> derives the pairing token — exists only in a [secure context], so a page served
> over plain HTTP from a LAN address cannot compute its own auth token: `e2ee.js`
> throws while loading and the client fails with `Can't find variable: E2EE`. The
> page therefore has to arrive over whatever secures the socket. In practice that
> means `https://` through the tunnel, or `http://127.0.0.1` (localhost is a
> secure context by definition); an SSH tunnel to loopback works too.
>
> Serving both from one port needs a demux: `NWProtocolWebSocket` never answers a
> plain `GET`, so the public port runs bare TCP, reads the request head, and either
> answers it as a static file or proxies the bytes to an internal loopback listener
> that keeps the real WebSocket stack (`HostGatewayServer`). The framework still
> owns every frame.

[secure context]: https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts

### 2.2 Pair URI (reuse wire shape)

```
seahelm://pair?b=<gateway_wss>&m=<mac_id>&k=<base64url root_secret>
```

Built by existing `MqttCrypto.pairURI(broker:macId:rootSecret:)`.

| Param | Meaning after this design |
|---|---|
| `b` | **Host Gateway WSS** public URL (via Tunnel), **not** the MQTT broker |
| `m` | Stable `mac_id` |
| `k` | 32-byte root secret (persist; today under `mqtt.root_secret`) |

**Reuse as-is**

- `PairingPaneView` / Settings Pairing page / menu pairing window  
- `mintPairingContext()` secret mint + persist  
- Web `applyPair` + `e2ee.js` (`parsePairURI`, HKDF auth + E2EE keys)  
- Same root secret for revoke-all: rotate `k` → old links and stored pairs die

**Change**

- The string passed into `PairingPaneView` as `brokerURL` must come from the Gateway public URL (e.g. `hostGateway.publicURL`), not `mqtt.resolvedClientBrokerURL` / `wss://…/mqtt`.  
- Settings copy should not imply “MQTT must be configured” for pairing to exist; pairing is for **remote access**, with MQTT optional for Watch.

**If Watch MQTT pairing must coexist later:** extend the URI (e.g. keep `b` for Gateway and add an MQTT endpoint param) or offer two Settings entry points. Web-first v1 uses a single `b=` = Gateway.

### 2.3 Threat model (URL leak)

| Attacker has | Result |
|---|---|
| Only `https://…` / `wss://…` | May load shell UI; Gateway auth fails |
| Full `seahelm://pair?…&k=…` | Fully authorized client |
| Already-paired browser (localStorage) | Authorized until revoke / rotate |

Do **not** treat random tunnel subdomains as the sole secret. Pairing secret is mandatory on every session.

### 2.4 Revoke (P0/P1)

- In-app “rotate pairing key”: new `k`, persist, drop existing Gateway sessions.  
- Optional later: per-client allowlist / kick.

---

## 3. Control plane and VT data plane

One authenticated WSS (message types on one connection; no requirement for two TCP sockets).

### 3.1 Control plane

Forward to existing `ControlRouter` / `ControlProtocol` (same methods as `~/.config/seahelm/seahelm.sock`).

Web v1 needs at least:

| Method | Use |
|---|---|
| `session.snapshot` / `pane.list` | First Mate list |
| `pane.send_keys` | Keystrokes into the open VT pty |
| `pane.send_text` / `pane.run` | Optional bulk inject |
| `suggest.pick` / `question.answer` | Waiting / 2FA cards if present |

List freshness: poll snapshot and/or push on `ShipLog` edges (implementation choice; semantics unchanged).

### 3.2 VT data plane

| Side | Choice |
|---|---|
| Mac capture | `zmx attach` via a PTY helper (same fidelity constraints as `devbroker/zmx-vt.js`) |
| Browser | xterm.js |
| Not used for web | Ghostty feed API; `zmx tail` / linear history |

Verb set (align with current web PoC; transport moves from MQTT topics to Gateway frames):

| Verb | Behavior |
|---|---|
| `pane.vt_open` | Attach; after quiet period emit `vt.snapshot`, then live `vt.data` |
| `pane.vt_keepalive` | Lease renewal so dead browsers do not hold attaches forever |
| `pane.vt_close` | Tear down **this** attach client only (never `zmx detach` that kicks every client) |
| `pane.send_keys` | Write key bytes to the attached pty |

**Geometry (accepted PoC constraint):** read real session cols/rows, pin the attach PTY to that size, send size with the snapshot. Remote adapts by font scaling; it must not resize the Mac pane.

### 3.3 Auth gates

Unauthenticated: reject snapshot, vt_*, send_*.  
Authenticated: Control-tier remote (full terminal). Optional v1.1: first remote write requires on-Mac confirm.

---

## 4. Config, tunnel ops, rollout

### 4.1 Config

- Keep pairing secret / mac id where they already live for now (`mqtt.root_secret`, `mqtt.mac_id`); optional later rename to neutral `remote.*` without breaking decode.  
- Add Host Gateway fields (names illustrative): local bind port, `publicURL` (feeds pair `b=`), tunnel id / notes.  
- MQTT remains optional and independent of web Gateway enablement.

### 4.2 Tunnel

- Cloudflare Tunnel (or equivalent) runs on the Mac, **independently of Seahelm**. It is
  not started, stopped, or supervised by the app; see the status note above for why.  
- Points at the Gateway's local port, which serves both the page and `/ws`. Same origin is
  required, not merely preferred — see §2 on secure contexts.  
- When Seahelm or the tunnel stops, remote access stops. No cloud broker required for this path.  
- The tunnel provides reachability only. Put an authorization layer in front of it
  (e.g. Cloudflare Access) if the hostname is public: the Gateway's token stops an
  unauthenticated caller, but anyone holding the token holds every pane.

### 4.3 Implementation phases

| Phase | Deliver | Explicitly not |
|---|---|---|
| **P0** | In-app Host Gateway: pair auth + snapshot + send_keys | Production VT-over-MQTT |
| **P0** | `vt_open` / data / close + in-process zmx attach | Ghostty feed |
| **P0** | Reuse Settings pairing; `b=` → Gateway URL | Second QR protocol |
| **P1** | ~~Tunnel setup UX~~ — dropped; tunnel stays uncoupled | Seahelm supervising `cloudflared` |
| **P1** | ✅ Same-origin web hosting (#56) | Hosting the client anywhere else |
| **P1** | Rotate key + drop old sessions | Short-code Watch PAKE |
| **P2** | Watch via MQTT if still desired | Treat `live-bridge` / `mock:zmx` as production |

`clients/seahelm-web`: production target = Gateway.  
`devbroker`: keep for protocol/regression only; README must say it is not the official “control my Mac” path.

### 4.4 Success criteria

1. URL alone cannot control Seahelm.  
2. After pairing: real fleet list; opening a pane yields a faithful live terminal with keyboard input.  
3. Rotating the pairing key immediately invalidates old browsers.  
4. No need to run aedes + mock to remotely control a live Seahelm.

---

## 5. Relationship to existing “messy” pieces

| Piece | Role after this design |
|---|---|
| `MqttChannel` + remote-clients MQTT doc | Watch/ESP / status+commands; not web VT |
| `seahelm-web` + MQTT.js | Retarget to Gateway; MQTT mode = debug |
| `devbroker` / `mock-seahelm` / `mock:zmx` | Local contract tests + VT fidelity experiments |
| `live-bridge.js` | Dev bridge to sock; not shipping architecture |
| `clients/seahelm-stack` (`gw.seahelm.dev`) | Optional edge for Watch/HTTP; not required for Mac-tunnel web |

---

## 6. Open implementation details (plan, not product forks)

These do not change the product decisions above; resolve in the implementation plan:

- Exact WSS frame schema (JSON-RPC vs typed envelopes for binary VT)  
- Whether E2EE envelopes wrap Gateway payloads the same way as MQTT topics, or TLS+pair-token is enough on a private tunnel endpoint  
- How Seahelm discovers/stores the Cloudflare public hostname  
- Attach process supervision and caps (max concurrent remote VTs)
