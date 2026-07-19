# Multi-platform Host & Remote Clients (direction)

**Date:** 2026-07-19  
**Status:** Direction approved for documentation — **not** an implementation plan  
**Scope of this doc:** Common Host foundation first; Windows / iOS / Android / ESP32 are follow-on tracks that consume it.

## Problem

Seahelm today is a macOS-only AppKit app: Ghostty terminals, zmx persistence, and a
local status pipeline (`StatusPublisher` → `ShipLog` → UI). We want:

1. **Windows** desktop parity with macOS (same product surface over time).
2. **iOS / Android** connected to a running macOS or Windows host for remote
   observation and light interaction.
3. **ESP32 (4″)** later, for simple status display and interaction.

Doing all three as one project is too large. This document locks the **shared
Host + remote protocol direction** so later client work does not fork.

## Decisions (locked)

| Topic | Choice |
|---|---|
| First deliverable | **Host common foundation** (not Windows UI, not mobile UI, not ESP firmware) |
| Process shape | **Fat Host sidecar** — Rust daemon `seahelmd` owns remote control plane |
| Daemon language | **Rust** (align with existing rmux / Rust infra) |
| Remote transport v1 | **LAN WSS**; **Cloudflare Tunnel optional** for away-from-home |
| Not in v1 transport | Public MQTT broker, NAT hole-punch / P2P WSS as primary path |
| Phone capability v1 | **Interactive tier** — pick server-issued suggest/question only; no free `send_text` |
| Pairing | **QR code** (address + one-time code → long-lived token); **manual IP/token** fallback |
| ESP32 | **Out of v1**; protocol should not block a later thin client |
| Status decision | Stays in **desktop App** (ShipLog / Detector / Aggregator) |
| Final message on phone | Push `lastMessage` / `lastAssistantMessage` on events + snapshot; optional capped `pane.read` |

## Non-goals (v1 Host)

- Full terminal streaming / pixel mirror to phone.
- MQTT, NATS, or self-hosted public message broker as the primary path.
- Hole-punch direct WSS as the only or default away path.
- ESP32 firmware or MQTT bridge.
- Windows Ghostty/UI port (separate track; reuses `seahelmd` + Backend IPC).
- Moving `StatusDetector` / rule engines into the daemon.
- Replacing local Unix control socket for in-machine agents/skills in v1 (may remain App-local).

## Related docs

- `docs/srp-protocol.md` — earlier protocol sketch (JSON-RPC methods, capability
  tiers, seq resume). **Semantic ideas remain useful**; transport/host topology
  in that file is **superseded** by this document (see banner there).
- [`2026-07-19-mobile-flutter-client-design.md`](2026-07-19-mobile-flutter-client-design.md) —
  Flutter M1 client IA (pairing, First Mate All/Orders, pane + prompt).
- `Sources/Core/ControlProtocol.swift` — existing local control API; remote
  surface is a capability-gated evolution, not a second unrelated RPC.
- `docs/technical-design.md` §6 — current agent status pipeline (read-screen + hooks → ShipLog).

---

## 1. Architecture: Fat Host

### Roles

| Process | Responsibility |
|---|---|
| **seahelmd** (Rust) | Sole remote Host: WSS listen, pairing/tokens, capability gates, JSON-RPC router, event subscribe + `seq` resume, fan-out to phones |
| **Seahelm App** (Swift today; Windows UI later) | Terminal engine, UI, **status decision + ShipLog**; implements **Backend** over localhost IPC |
| **iOS / Android** | Connect only to `seahelmd`; v1 = interactive tier |
| **cloudflared** (optional) | Expose local WSS via Cloudflare Tunnel; protocol-agnostic |

```
┌─────────────┐     WSS (LAN / optional CF Tunnel)     ┌──────────────┐
│ iOS/Android │ ─────────────────────────────────────► │  seahelmd    │
└─────────────┘                                        │  auth/rpc/   │
                                                       │  event bus   │
                                                       └──────┬───────┘
                                                              │ Backend IPC
                                                              │ (localhost)
                                                       ┌──────▼───────┐
                                                       │ Desktop App  │
                                                       │ Ghostty/UI/  │
                                                       │ ShipLog      │
                                                       └──────────────┘
```

### Boundary rules

1. Phones **never** talk to the App process directly — only to `seahelmd`.
2. `seahelmd` **does not** own PTY/Ghostty; pane read, suggest pick, snapshots
   go through Backend IPC into the App.
3. Local CLI / agent skills may keep using today’s Unix control socket on the
   App for v1; **all remote traffic** goes through the daemon.
4. Windows later swaps the App/Backend implementation; `seahelmd` + phone
   protocol stay the same.

---

## 2. Status ownership (ShipLog)

Split **decision** from **fan-out**:

| Concern | Owner |
|---|---|
| Detect / aggregate pane & worktree status | **Desktop App** (`StatusPublisher`, `StatusDetector`, hooks, `WorktreeStatusAggregator`, `ShipLog.ingest`) |
| Canonical store for local UI | **ShipLog in App** (v1) |
| Remote event bus, `seq`, snapshot cache for clients | **seahelmd** |

```
StatusPublisher / hooks / Detector / Aggregator  (App)
        │  committed status + messages + suggest/question
        ▼
   ShipLog (App UI source of truth) ──push──► Backend IPC
                                                    ▼
                                               seahelmd event bus
                                                    ▼
                                                 phone WSS
```

**v1 does not** move ShipLog into the daemon. A later option is
“daemon holds canonical ShipLog, App subscribes back” — explicitly out of scope
here due to UI churn.

---

## 3. Transport & ops

### v1 default: LAN WSS

- `seahelmd` listens on localhost-adjacent / LAN bind (exact bind policy TBD in
  implementation plan: prefer least surprise + least accidental WAN exposure).
- Clients use `wss://` when TLS is configured; LAN may start with `ws://` behind
  pairing token if TLS-on-LAN is deferred — **token still required**.

### Away mode: Cloudflare Tunnel (optional)

```
Phone ──wss://…──► Cloudflare Edge ──tunnel──► cloudflared ──► seahelmd (localhost)
```

- Same JSON-RPC and auth as LAN; only the ingress changes.
- Not hole-punching; still a relay, with much less ops than running EMQX/NATS.
- Tunnel provisioning: **user-optional** (“出门模式”); not required for LAN use.

### Rejected for v1 (kept for later comparison)

| Alternative | Why deferred |
|---|---|
| Public MQTT (e.g. EMQX) | Better for ESP; more broker ops; phone RPC is clumsier |
| NATS as primary | Weaker ESP story; still a public message plane to run |
| NAT hole-punch WSS | Unreliable NATs; needs TURN fallback ≈ broker complexity |

ESP later may reintroduce MQTT as an **adapter** in front of the same semantic
layer; not a second product protocol.

---

## 4. Wire protocol (semantic layer)

Evolve from `ControlProtocol` + ideas in `docs/srp-protocol.md`:

- JSON-RPC 2.0 (`jsonrpc`, `id`, `method`, `params` / `result` / `error`).
- `initialize` with `protocolVersion`, `clientInfo`, `capabilities`, `token`.
- Server returns negotiated capabilities and allowed methods.
- Notifications (no `id`) for events; client `subscribe` with topics + optional
  `sinceSeq` for resume.
- Encoding v1: **JSON text frames on WebSocket**. Protobuf/MQTT are non-goals
  for v1 (may return for ESP).

### Capability tiers (tokens)

| Tier | Phone v1 | Methods (illustrative) |
|---|---|---|
| Read | included in Interactive | `session.snapshot`, `pane.list`, `pane.read` (capped), subscribe to status |
| Interactive | **default for paired phone** (= Read ∪ pick) | `suggest.pick`, `question.answer` (only server-issued IDs) |
| Control | **not** granted by default | `pane.send_text`, `pane.run`, split/focus/close, … |

Interactive is a **superset of Read**. It is the security wedge: a leaked
interactive token can observe and press host-offered buttons, but cannot
free-type into a pane.

### Errors

Reuse JSON-RPC standard codes; business codes aligned with existing
`ControlError` / SRP sketch (`capability_denied`, `stale_suggest`,
`seq_gap_unrecoverable`, …).

---

## 5. Backend IPC (App ↔ seahelmd)

Stable, narrow contract — **not** opaque JSON passthrough of arbitrary UI.

### App → daemon (push)

- Status transitions (pane/worktree rolled up as needed).
- `lastMessage` / `lastAssistantMessage` when they change meaningfully.
- `suggest` / `question` payloads (ids + options + optional preface text).
- Notifications suitable for remote watch (optional subset).

### Daemon → App (request)

- `snapshot` — pane list + status + message fields. **v1 default:** daemon
  forwards each `session.snapshot` to the App (no stale cache required); optional
  daemon-side cache is an optimization for a later plan.
- `pane.read` — capped lines / source (for phone detail).
- `suggest.pick` / `question.answer` — validate id+index, perform local action.
- Health / “backend attached” handshake on App launch.

Transport for IPC: localhost Unix socket (macOS) / equivalent on Windows later;
framing TBD in implementation plan (newline JSON or length-prefixed). Must be
unreachable from the LAN bind of WSS.

---

## 6. Final message on iOS (and Android)

Goal: phone sees **at least** the agent’s final / latest summary text — not a
live terminal.

### Primary: push summaries

Fields already produced in-app today:

- `lastMessage` — viewport extract via status poll rules.
- `lastAssistantMessage` — hook paths (e.g. Stop) via `noteAssistantMessage`.

Delivery:

1. Include both on `session.snapshot` / pane records.
2. Push on `event.status` when status becomes `waiting` / `idle` / `error`, or
   when `lastAssistantMessage` updates.
3. Attach preface text on `event.suggest` when presenting choices.

`seahelmd` fans these out; it does not re-extract from the PTY.

### Secondary: capped `pane.read`

- Allowed on interactive-tier tokens with hard limits (e.g. `lines ≤ 30`,
  response truncation).
- Used when user opens detail and summary is insufficient.
- **No** subscribe-to-scrollback streaming in v1.

---

## 7. Pairing & discovery

1. Desktop shows QR: LAN URL (or host:port) + short-lived pairing secret.
2. Phone scans → exchanges secret for long-lived token bound to **interactive**
   capabilities (and device id).
3. Fallback: user enters host + token manually (debug / mDNS failure).
4. Token storage on phone; revoke from desktop settings (implementation detail).

**Ownership split (direction):** `seahelmd` is the authority for issuing,
validating, and revoking tokens; the desktop App only renders QR / settings UI
and asks the daemon for pairing material over Backend IPC. Exact message names
belong in the H0 implementation plan.

Away mode: same token against the Cloudflare hostname once Tunnel is enabled.

---

## 8. Current macOS information flow (baseline)

Unchanged by Host for local UI. Typical path:

```
Agent (in zmx) → Ghostty surface
    → StatusPublisher (~2s readViewportText + process/OSC)
    → StatusDetector → DebouncedStatusTracker
    → NormalizedEvent → ShipLog.ingest
    → WorktreeStatusAggregator / NotificationManager / UI
```

Parallel high-authority path: agent hooks → localhost `WebhookServer` →
`NormalizedEvent(.hook)` → same `ShipLog.ingest`.

Remote addition after ingest:

```
ShipLog / suggest path → Backend push → seahelmd → WSS clients
```

---

## 9. Multi-track roadmap (ordered)

Independent specs/plans later; this doc only sequences them:

| Track | Depends on | Notes |
|---|---|---|
| **H0** seahelmd + Backend IPC + LAN WSS + pairing | — | This direction |
| **H1** Optional Cloudflare Tunnel “away mode” | H0 | Same protocol |
| **M1** Flutter iOS+Android client | H0 | See [`2026-07-19-mobile-flutter-client-design.md`](2026-07-19-mobile-flutter-client-design.md) — All/Orders, compact Repo→WT→Pane, pane prompt UI |
| **W1** Windows desktop App + Backend | H0 | Reuse daemon; terminal engine TBD |
| **E1** ESP32 4″ | H0 + likely MQTT adapter | Thin interactive/read display |

---

## 10. Open points (for implementation plan, not blockers for direction)

1. Exact LAN bind address / port / TLS-on-LAN policy.
2. Backend IPC framing and packaging (`seahelmd` binary location vs rmux workspace).
3. Whether local Unix `ControlProtocol` is adapted behind Backend or stays parallel long-term.
4. Seq buffer size and snapshot-forced resume UX on phone.
5. Cloudflare: user-owned Tunnel vs product-assisted setup (v1 = optional user setup is enough).

---

## 11. Success criteria (direction-level)

**H0 (Host foundation — this track’s “done”):**

- `seahelmd` accepts LAN WSS, completes pairing, enforces interactive-tier gates.
- Backend IPC carries status/suggest pushes and snapshot/pick/read requests.
- An integration client (script or debug tool — **not** requiring a shipped
  App Store phone app) can subscribe, see status + final message fields, and
  successfully `suggest.pick` / `question.answer`.

**Product north-star (H0 + M1):**

- A paired phone on the same LAN sees worktree/pane status and **final message**
  text, and can pick **suggest/question** options.
- Compromised interactive token cannot free-type into a pane.
- Desktop status remains App-owned; daemon required only when remote is enabled
  (local-only use must not regress).
- Windows and ESP can be scheduled without redesigning phone↔host semantics.
