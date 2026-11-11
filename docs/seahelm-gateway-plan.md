# seahelm-gateway

Status: built (2026-11-04), one PR: the crate, the core additions, the web client on cards,
the app's gateway / Telegram / Gmail code deleted and its settings on `gateway.sock`. Boundary: `docs/target-architecture.html`
("core 与 gateway 的边界"). Hard cut: no switch, no shadow phase. The one thing kept
is the pairing root secret, so devices paired before stay paired.

Decided 2026-11-04:
1. The Gmail mail channel is deleted, not moved.
2. Per-device tokens ship in this change.
3. The web's split button becomes "new pane": the core starts a session in that worktree,
   and the desktop places it. `layout.live` mirroring went with the app link; the
   page mirrors the desktop again through the core instead (`layout.get`, below).
4. tokio / axum / reqwest live in the gateway crate only.

## Components

```
seahelm-web ─┐  wss (unchanged wire)        ┌─ core.sock   (JSON-RPC, public methods + events.subscribe + message.subscribe)
Telegram ────┼─ seahelm-gateway ────────────┤
App/GPUI/CLI ┘  gateway.sock (admin)        └─ seahelmd sockets (terminal streams, direct)
```

- Crate `seahelmd/crates/gateway`, binary `seahelm-gateway`. It ships in `Contents/Resources/bin`
  beside `seahelm-core`, and in the GPUI bundle on Linux and Windows.
- `seahelm-gateway serve` runs it in the foreground. `seahelm-gateway ensure` starts it detached
  unless it already answers on `gateway.sock`; that is how the app starts it, the same way it
  starts the core. Single instance: `gateway.sock` refuses to bind while a live gateway answers.
- It never starts the core. When the core is unreachable it retries every second, and the web
  shows the fleet as empty.
- Files live under `~/.config/seahelm/gateway/` (dir 0700, files 0600):

| File | Holds | Shape |
|---|---|---|
| `config.json` | settings | `{web: {enabled, port, public_url, web_root, telegram_host}, telegram: {enabled, allowed_users, default_chat_id, backfill_seconds, rules, mini_app_url}}` |
| `secrets.json` | secrets | `{root_secret, mac_id, pair_code, telegram_bot_token}` |
| `state.json` | live state | `{devices: [...], share_links: [...], chat_sessions: {...}}` |
| `telegram/` | Telegram adapter | the adapter's own small state |

- Socket `gateway.sock`: `$SEAHELM_GATEWAY_SOCKET`, else `~/.config/seahelm/gateway.sock`
  (Windows: `\\.\pipe\seahelm-gateway-<user>`).

## Import (first start)

When `gateway/config.json` does not exist, the gateway reads the legacy sources. It never
writes them.

From `~/.config/seahelm/config.json`:

| Legacy key | Goes to |
|---|---|
| `mqtt.root_secret`, `mqtt.mac_id` | secrets |
| `host_gateway.enabled`, `port`, `public_url`, `web_root`, `telegram_host` | `config.web` |
| `host_gateway.pair_code` | `secrets.pair_code` |
| `telegram.bot_token` | `secrets.telegram_bot_token` |
| `telegram.allowed_users`, `default_chat_id`, `auto_connect` (→ `enabled`), `backfill_seconds`, `rules`, `mini_app_url` | `config.telegram` |

From the other files:

| Source | Goes to |
|---|---|
| `~/.config/seahelm/share-links.json` | `state.share_links`; tokens are hashed, so the links keep working |
| `~/.config/seahelm/command-sessions.json`, entries keyed `telegram:<chat>` | `state.chat_sessions` |

- New files are written to a temp file and renamed. Secrets go in last, and the import only
  counts as done once `config.json` exists.
- A missing root secret is minted: 32 random bytes, base64url. A missing mac id is derived
  from the host name.
- The app stops writing these keys (the Swift fields are deleted), so they vanish on its
  next config save.

## Auth

- **Legacy token:** `hex(HKDF-SHA256(ikm=root_secret, salt="seahelm-pair-v1", info="auth", 32))`.
  It is accepted only as `auth {mac_id, token}` with a matching mac id, and is always exchanged
  for a device token.
- **Device token:** 32 random bytes, hex. `state.devices[]` stores
  `{id, label, via: "code"|"telegram"|"legacy", token_hash (sha256 hex), created_at, last_seen_at}`.
  It is issued on every successful code, Telegram or legacy sign-in, and returned as `result.token`;
  the page already stores whatever comes back there.
  - A device-token sign-in returns the same token and updates `last_seen_at`, written at most
    once a minute.
  - Revoking a device drops its open connections.
- **Pairing code:** 8–16 digits, generated as 8.
  - Limited to 5 failures per 60 s per client IP; a failure past that answers `-32029 rate_limited`.
  - Behind the local tunnel the client IP is `CF-Connecting-IP` when the TCP peer is loopback.
  - The code is refused on the Telegram-only host.
- **Telegram Mini App:** `telegram_init_data` is validated with an HMAC over every field but
  `hash`, `signature` included. Its age must be ≤ 86400 s, with 300 s of slack for clock skew,
  and the user must be on `allowed_users` (numeric id or `@username`, case-insensitive).
- **Telegram-only host:** `config.web.telegram_host`, else the host of `config.telegram.mini_app_url`.
  The Host header is read on the upgrade request itself; there is no proxy hop any more.
- **Share link:** `auth {share, pane, name?}`. The token is matched by sha256 against
  `state.share_links`. The reply is `reason: "expired"|"invalid"|"name_required"` when refused.
  - No token is issued.
  - The connection is scoped to that pane, and text sent with Enter is prefixed `[from <name>] `.
  - Revoking, expiry and a recipient change each drop open connections; expiry is checked every 30 s.
- `pairing.revoke_all` mints a new root secret and a new code, clears devices, and drops every
  connection.

## Web wire protocol (gateway ↔ seahelm-web)

Same framing as before. Text frames carry JSON:

- request `{id, method, params}`
- response `{id, result}` | `{id, error: {code, message}}`
- notify `{type: "notify", method, params}`

Binary VT frames and binary key frames are unchanged:

- VT frame: `u8 ver=1, u8 flags (bit0 = raw deflate, RFC 1951, no zlib header), u8 kind (1 data, 2 snapshot),
  u8 keylen, key, [u16 BE cols, u16 BE rows if snapshot], payload`. Payloads of 512 bytes or
  more are deflated when the client negotiated it and the result is smaller.
- Key frame: `u8 ver=1, u8 kind=1, u8 keylen, key, utf8`.

Ping every 30 s; a socket silent for 75 s is closed.

### `auth`

Params: `{mac_id?, token?, code?, telegram_init_data?, share?, pane?, name?, vt_binary?,
vt_deflate?, keys_binary?, since_seq?}`. Precedence: share, then token, then Telegram, then code.

Result:

```
{ok, reason?, vt_binary, vt_deflate, keys_binary,
 mac_id, token?, share?, share_sender?,
 replay: "full"|"delta", reset_panes?: [key],
 panes: [Pane]}
```

Then notifies follow, in order: `cards {cards}`, then `pane.message` for each timeline row
(the whole ring, or the rows after `since_seq` when the core can replay them), then
`autopilot.state` (paired clients only).

- **Pane:** core `pane.list` rows: `{pane_id, pane_session_key, worktree_path, branch, project,
  agent_type, status, last_message, title, unseen?, handle?}`. First Mate's pane is
  `seahelm-first-mate`, and is left out of share connections.
- **Card:** core card JSON: `{id, kind: question|choice|suggestion|report|approval|proposal,
  pane_session_key, pane_id, worktree_path, branch, project, message, options, labels,
  multi_select?, checked?, payload?, created_at, fresh_at}`.

### Notifies

| Method | Params | Sent when |
|---|---|---|
| `pane.status` | `{pane_id, pane_session_key, status, old_status, agent_type, worktree_path, last_message, unseen?}` | `pane.status_changed`; `pane.updated` only when agent_type changed for that connection; `pane.unseen_changed` with `{pane_id, pane_session_key, worktree_path, unseen}` |
| `pane.closed` | `{pane_id, pane_session_key, worktree_path}` | the pane closed |
| `pane.added` | Pane | `pane.registered` from the core (new) |
| `pane.message` | core message row | every timeline row (core `message.subscribe`) |
| `cards` | `{cards: [Card]}` | the full current list, on every `cards.changed`; scoped to the pane on share connections |
| `autopilot.state` | core `autopilot.state` | whenever it changes; the gateway polls every 2 s and diffs |

### Methods

| Method | Does |
|---|---|
| `ping` | |
| `session.snapshot` / `pane.list` | `{panes}` |
| `fleet.groups {mode: repository\|status\|activity}` | `{mode, groups: [{id, title, status?, unseen?, items: [{id, worktree_path, repository, status, is_main_worktree, last_activity_at?, running_since?, unseen?, title?, pr?}]}]}`, computed in the gateway from core `worktree.list` + `pane.list` |
| `pane.vt_open {pane_session_key}` | `{ok, cols, rows}` |
| `pane.vt_size {pane_session_key, cols, rows}` | `{ok}`; re-attaches the open stream as a viewer of that size (clamped to 20×5–500×200; 0×0 = passive again), dropping the old attachment once the new one has its screen. seahelmd fits the session to its smallest viewer, so the desktop pane shrinks while the page looks; the new grid arrives as the next snapshot. `take_over: true` attaches with seahelmd's `TakeOver` instead: the session is sized for the page alone, and a desktop pane the grid no longer fits shows a notice until the page lets go. The answer's `take_over` says whether it did (a daemon started before `TakeOver` gets a plain sized attach). Refused on a share link |
| `layout.get {worktree_path}` | core: `{root, focused_pane_session_key}`, the split tree a desktop client shows for the worktree (the macOS app hands the core all of them every 2 s, `layouts.set`), or `{root: null}`; the page stacks the panes then |
| `pane.vt_close` | local to the gateway |
| `pane.vt_keepalive` | local to the gateway; a stream is reaped after 60 s without one |
| `pane.send_keys` | `{pane_session_key, b64\|text}` on an open VT → the stream (`{sent}`); otherwise core `pane.send_keys {pane_id, keys}` |
| `pane.send_text {pane_id, text, enter}` | core |
| `pane.seen` | core |
| `message.history` | core |
| `cards.answer {id, index}` | core (new for the web) |
| `cards.dismiss {id}` | core (new for the web) |
| `worktree.options` | core (new core method) |
| `worktree.create {repo_path, agent_type, prompt}` | core; slow, so it runs off the session task |
| `pane.new {pane_session_key\|worktree_path}` | core (new) |
| `pane.close {pane_session_key}` | core (new) |
| `autopilot.state` | core |

Every call to the core carries `_meta: {via: "web:<device label>"}`.

**Removed:** `pane.event` notifies and `question.answer` / `suggest.pick` / `decision.dismiss` /
`autopilot.answer` (use cards); `layout.live` (now `layout.get`, from the core); `pane.split`.

**Share connections may call:** `ping`, `session.snapshot`, `pane.list`, `fleet.groups`,
`pane.vt_*`, `pane.send_keys`, `pane.send_text`, `pane.seen`, `message.history`, and
`cards.answer` / `cards.dismiss` on cards of the shared pane. Every pane reference must name
the shared pane. Anything else answers `-32003`.

## Core additions

| Addition | Shape |
|---|---|
| `worktree.options` | `{repos: [{name, path}], agents: [{id, label}]}`: repos from the listed worktrees' main checkouts, agents `claudeCode` / `codex` when on PATH |
| `pane.new {worktree_path, agent_type?}` | Starts a seahelmd session in that worktree (a shell, or the agent) and registers it. Publishes `pane.registered` (Pane fields) and returns `{pane_session_key}`. The app adopts a registered session it has no pane for as a new split leaf in that worktree. |
| `pane.close {pane}` | Kills the seahelmd session, unregisters the pane, and publishes `pane.closed` with `by_request: true`. The app removes that leaf. |
| `autopilot.audit` event | `{type: "autopilot.audit", entry}` for each line First Mate writes to `audit.jsonl` |
| `_meta.via` | Accepted on any call. Recorded on `card.answered` and in First Mate's audit as `via`. Never used for authorisation. |
| `pane.registered` event | Published on every register |

## gateway.sock (admin, local only)

JSON-RPC, one request per line; `events.subscribe` turns the connection into a stream.

| Method | Params | Result |
|---|---|---|
| `gateway.ping` | | `{ok, version, pid}` |
| `gateway.status` | | `{web: {enabled, listening, port, public_url, error?, clients}, telegram: {enabled, configured, connected, bot_username?, error?}, core: {reachable}}` |
| `gateway.config.get` | | `{web: {enabled, port, public_url, web_root, telegram_host}, telegram: {enabled, bot_token_set, allowed_users, default_chat_id, backfill_seconds, rules, mini_app_url}}` |
| `gateway.config.set` | `{web?: {...partial}, telegram?: {...partial, bot_token?: string; "" clears}}` | same as get; applied live (listener rebinds, bot reconnects) |
| `pairing.code.get` | | `{code, pair_url}` |
| `pairing.code.refresh` | | `{code, pair_url}` |
| `pairing.code.set` | `{code}` | `{code, pair_url}`; `-32602` if not 8–16 digits |
| `pairing.revoke_all` | | `{ok}` |
| `devices.list` | | `{devices: [{id, label, via, created_at, last_seen_at, connected}]}` |
| `devices.revoke` | `{id}` | `{ok}` |
| `share.create` | `{pane_session_key, label?, lifetime_seconds?: number\|null, recipient?}` | `{id, url, expires_at}` |
| `share.list` | | `{links: [{id, pane_session_key, label, recipient, created_at, expires_at}]}` |
| `share.update` | `{id, lifetime_seconds?, recipient?}` | link |
| `share.revoke` | `{id}` or `{pane_session_key}` | `{ok}` |
| `telegram.validate_token` | `{bot_token}` | `{ok, username?, error?}` |
| `telegram.pair.begin` | | `{code, deep_link}`; the next `/start <code>` from anyone adds them to `allowed_users`, sets `default_chat_id` if empty, and emits `telegram.paired {user_id, display, chat_id}` |
| `telegram.pair.cancel` | | |
| `events.subscribe` | | events `gateway.status_changed`, `telegram.paired`, `devices.changed`, `share.changed`, `config.changed` |

Each pane's URL is `public_url` (or `http://<lan ip>:<port>`) with `/?pane=<key>&share=<token>`
appended; `pair_url` is the bare `public_url`.

## Telegram in the gateway

Behaviour is ported from the app as it was (see the CLAUDE.md `ExternalChannel` paragraph). The
sources it now talks to:

| Concern | Where it comes from in the gateway |
|---|---|
| Orders from allowed users | `command.run {text, context: {binding, via: "telegram:@name"}}`; the binding is kept per chat in `state.chat_sessions` |
| Rule input from anyone else | Run through the rule engine; actions go through core business methods |
| Notices | `pane.notice` event → the bound chat, else `default_chat_id`; the pane's `#n` (core `pane.list` handle) goes on line two; nothing is sent if the bound pane is gone |
| Cards | `cards.changed` → inline buttons through a callback registry; a tap answers `cards.answer` |
| Progress | pane events + `message.subscribe`: per pane in groups (edited, then deleted), a `sendMessageDraft` board in private chats (resent every 8 s); Stop sends `pane.send_keys escape` |
| First Mate | `autopilot.say` records the asking chat, and the reply goes out on the `seahelm-first-mate` completion; `autopilot.audit` `.action` lines go out too |
| Media | Downloaded for allowed users only, to `gateway/telegram/media/<uuid>/`, and passed as paths |
| Mini App menu button | `setChatMenuButton` to `mini_app_url` on every connect |
| HTTP | reqwest + rustls with a pooled client; long poll on its own task |
