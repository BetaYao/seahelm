# Short numeric pairing code for Host Gateway

> **Status:** Draft for review (2026-08-28 brainstorm)  
> **Goal:** Pair a browser to a Mac Host Gateway by entering an 8-digit code on the page you already opened — works on plain HTTP and HTTPS, with no URL or secret in the pairing payload.  
> **Replaces for web:** `seahelm://pair?b=…&m=…&k=…` QR / long-link pairing in Settings and the web gate UI.

---

## 0. Decisions locked in brainstorm

| Question | Choice |
|---|---|
| Code shape | **8-digit numeric** (Settings shows grouped, e.g. `4829 1736`) |
| Code lifetime | **Until manual refresh** on the Mac (no auto TTL) |
| After success | **Remember** — browser stores long-lived `token` in `localStorage`, auto-reconnect |
| Legacy pair URI | **Full replace** in Settings / web — no QR, no long link (Watch/MQTT pairing deferred) |
| Approach | **Short code + server-issued token** — browser never runs HKDF / WebCrypto for Gateway auth |

---

## 1. User flows

### 1.1 Mac — Settings → Remote pairing

- Large **8-digit code** (monospaced, copy button).
- **Refresh code** — new random code; previous code rejected immediately.
- **Revoke all remotes** — rotate `mqtt.root_secret`; invalidates every stored browser token and forces a new code.
- Helper text: *Open the access URL shown below in a browser, then enter this code.*  
  Access URL comes from `HostGatewayConfig.resolvedPageURL` (e.g. `http://100.103.37.3:2783/`, `http://127.0.0.1:2783/`).
- **Removed:** QR, `seahelm://pair` long link, copy-link for pair URI.

### 1.2 Browser — any reachable Gateway origin

1. User navigates to the Gateway page (`http` or `https`).
2. Gate shows 8-digit input + **Pair & connect**.
3. Client opens **same-origin** WebSocket: `ws(s)://<host>/ws` (path from current page, not from any pairing payload).
4. `auth` with `{ code, vt_binary, vt_deflate }`.
5. On success, store `{ m: mac_id, t: token }` in `localStorage`; render fleet.
6. Next visit: if creds present, `auth` with `{ mac_id, token, vt_binary, vt_deflate }` only.

**Plain HTTP works** because the Mac derives `token` server-side; the browser never touches `crypto.subtle` or `e2ee.js` on the Gateway path.

---

## 2. Wire protocol

Single WSS connection; extend existing `auth` method.

### 2.1 First-time pairing (code)

**Request**

```json
{
  "id": "1",
  "method": "auth",
  "params": {
    "code": "48291736",
    "vt_binary": true,
    "vt_deflate": true
  }
}
```

**Success**

```json
{
  "id": "1",
  "result": {
    "ok": true,
    "mac_id": "m3e530892",
    "token": "<64-char hex, HostGatewayAuth token>",
    "vt_binary": true,
    "vt_deflate": true
  }
}
```

**Failure**

```json
{
  "id": "1",
  "error": { "code": -32001, "message": "unauthorized" }
}
```

Or rate limit:

```json
{
  "id": "1",
  "error": { "code": -32029, "message": "rate_limited" }
}
```

### 2.2 Return visit (stored token)

Unchanged from today:

```json
{
  "id": "2",
  "method": "auth",
  "params": {
    "mac_id": "m3e530892",
    "token": "<hex>",
    "vt_binary": true,
    "vt_deflate": true
  }
}
```

### 2.3 Precedence

- If `token` + `mac_id` present and valid → authenticate (skip code).
- Else if `code` present → verify against current `PairingCodeStore` code.
- Else → `unauthorized`.

Negotiation flags (`vt_binary`, `vt_deflate`) behave as today.

---

## 3. Mac components

### 3.1 `PairingCodeStore`

- Field: `host_gateway.pair_code` (string, exactly 8 digits, zero-padded).
- On first launch / missing code: generate and persist.
- `refresh()` → new `SecRandom`-backed code, persist, return display string.
- `verify(_ code: String) -> Bool` — normalize input (strip spaces), constant-time compare against stored code.

### 3.2 `PairRateLimiter`

- Tracks failed **code** attempts per client IP (from `HostGatewayServer` front listener).
- Policy: **5 failures / 60 s / IP** → reject with `-32029` for 60 s.
- Successful code auth resets or does not increment (implementation choice; must not lock out legitimate user after one typo if under cap).
- Token-based auth failures use existing path; optional separate counter (same IP cap).

### 3.3 `HostGatewaySession.handleAuth`

Extend to branch:

1. Token path — existing `HostGatewayAuth.verify`.
2. Code path — `PairingCodeStore.verify` + `PairRateLimiter` allow/check + on success issue same `token` as token path would expect.

### 3.4 Settings UI — `PairingPaneView`

Replace QR/link pane with:

- Code label (large type)
- Copy code
- Refresh code (calls store + updates label)
- Access URL label (read-only, copy)
- Revoke all remotes (existing root rotation if present; wire if missing)

Remove `brokerURL` property and QR generation.

---

## 4. Web client (`clients/seahelm-web/index.html`)

- Gate: 8-digit numeric input; remove textarea for `seahelm://pair`.
- Remove `applyPair`, `E2EE` dependency for Gateway connect path.
- `connectGateway()`: always `new WebSocket(\`${wsScheme}//${location.host}/ws\`)`.
- `localStorage` key unchanged in spirit; shape `{ m, t }` without `b`.
- Disconnect / unpair clears stored creds.
- Error copy for wrong code vs rate limit vs offline.

MQTT debug mode (`?mqtt=1`) unchanged; may still use `e2ee.js` for broker creds.

---

## 5. Security

| Topic | Decision |
|---|---|
| Code entropy | 10⁸ values; **rate limiting is mandatory** because there is no TTL |
| Refresh code | Invalidates old code only; **does not** revoke existing browser tokens |
| Revoke all | Rotates `root_secret` → all tokens dead, new code required for new browsers |
| Attacker model | Must reach Gateway URL (Tailscale, LAN, or exposed port) **and** guess/brute code |
| Token storage | Same as today — scoped hex in `localStorage`; not extractable goal, convenience default |

---

## 6. Scope & breaking changes

| In scope | Out of scope (this spec) |
|---|---|
| Host Gateway web pairing | Watch short-code PAKE (deferred) |
| Settings pairing pane rewrite | MQTT client pairing via 8-digit code |
| Remove web long-link gate | `seahelm-stack` / EMQX pairing UX |
| Unit tests for store, auth, limiter | E2EE envelope for Gateway (still TLS/code/token) |

**Breaking:** Settings no longer shows `seahelm://pair` or QR. Users with bookmarked long links must use code flow. Document in release notes.

---

## 7. Testing

- `PairingCodeStoreTests` — generate, refresh invalidates old, verify normalizes spaces.
- `HostGatewaySessionTests` — code auth ok, bad code, refreshed code rejects old.
- `PairRateLimiterTests` — 6th failure in window → rate_limited.
- Manual — `http://<tailscale-ip>:2783/` pair without HTTPS; reconnect after reload.

---

## 8. Success criteria

1. Plain `http://100.x.x.x:2783/` pairs with 8-digit code, no console crypto errors.
2. Pair payload contains **no URL** and **no root secret**.
3. Reload page auto-connects with stored token.
4. Refresh code on Mac blocks new pairings with old code; existing session stays up.
5. Revoke all remotes forces re-pair on every browser.
