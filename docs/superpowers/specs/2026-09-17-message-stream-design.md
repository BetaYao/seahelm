# MessageStream for seahelm-web text mode

> **Status:** Accepted for planning (2026-09-17)  
> **Scope:** Project a typed per-pane message timeline from `AgentRegistry` ingest; expose it on Host Gateway / control socket; make seahelm-web phone default use that timeline instead of VT  
> **Out of scope:** Full multi-turn transcript persistence, MessageStream driving First Mate, mandatory screen-scraped chat for hookless agents, Seahelm-operated public relay

## Problem

`seahelm-web` today is a remote-desktop client: Host Gateway + `zmx attach` VT into xterm.js. That path is correct for fidelity and already supports user tunnels (Tailscale / Cloudflare), but VT is too heavy for the primary phone job — fleet status, approve cards, send an order, glance at what the agent is doing.

A live dump of the control socket showed the gap clearly:

- `session.snapshot` exposes `status` + `last_message` only.
- `AgentRegistry` already holds richer narrative material (`activityEvents`, `lastUserPrompt`, `lastAssistantMessage`, `eventLog`) that never reaches the web client as a timeline.
- Overloading `last_message` for both tool crumbs (`Shell`, `Core/PaneInfo.swift`) and assistant prose makes heuristic “wash” in the browser unreliable.

Poor-network work on VT (single-pane default, backpressure, binary frames) keeps the stream alive; it does not change the product shape.

## Goals

| Goal | Success signal |
|---|---|
| Phone default needs no VT | Opening a pane on a narrow viewport shows a typed timeline without `pane.vt_open` |
| Clean kinds, not soup | Wire events are `user` / `assistant` / `tool` / `status` / `decision` / `notice` — not one overloaded `last_message` |
| Registry stays SSOT for state | Island, First Mate, status dots still read `PaneInfo`; MessageStream is an append-only projection |
| Agent differences are small config | Optional `message` block on existing `agents/<id>.json`; no second regex Manifest for chat |
| Reachability unchanged | User-provided tunnel only; Gateway auth unchanged |

## Non-goals (this iteration)

- Disk-persisted conversation history across app restarts
- Replacing Telegram as the push “bell” on iOS
- Building or requiring a Seahelm-hosted relay
- Viewport-regex “chat extraction” as the primary path
- Removing VT (it remains opt-in for strong links / TUI work)

## Decisions locked in brainstorm

| Question | Choice |
|---|---|
| Product job | Phone remote control (fleet + cards + light input) |
| Client shape | Existing Host Gateway + `seahelm-web` (not a new stack) |
| Reach | User tunnel (Tailscale / Cloudflare / etc.) |
| Default pane surface | Text / MessageStream; VT on demand |
| Narrative layer | `PaneMessageProjector` → `MessageStreamHub` after Registry |
| Per-agent rules | Light `message` JSON on agent manifests; not a second status-style Manifest |

---

## 1. Architecture

```
  hook / scan                 every event / poll
       │                            │
       ▼                            ▼
  NormalizedEvent ──► PaneReducer (pure) ──► AgentRegistry (snapshot SSOT)
                                                    │
                                                    │ IngestOutcome
                                                    ▼
                                         PaneMessageProjector (pure)
                                                    │
                                                    ▼
                                         MessageStreamHub (ring + seq)
                                                    │
                         ┌──────────────────────────┼──────────────────┐
                         ▼                          ▼                  ▼
                   Host Gateway              Control socket      (optional later)
                   pane.message              message.*           Telegram history UI
                         │
                         ▼
                   seahelm-web text mode
```

**Hard rules**

1. MessageStream does **not** write back into `AgentRegistry` / `PaneInfo`.
2. Island / First Mate / status bar keep consuming Registry (and existing decision notifies). Do not route them through MessageStream in v1.
3. `EventHub` today is status-centric and lossy for narrative. Prefer a dedicated `MessageStreamHub` (or clearly versioned `pane.message` notifies) rather than overloading `pane.updated`’s `last_message`.
4. `ChatProgressReporter` already projects tool progress for Telegram; generalize its “what is the agent doing” idea into `PaneMessageProjector`, then let Telegram keep its own send/edit policy.

---

## 2. Event kinds (wire-stable)

| kind | Produced when | Typical UI |
|---|---|---|
| `user` | `NormalizedEventKind.userPrompt` | Outgoing bubble |
| `assistant` | Completion path with non-empty `lastAssistantMessage` (and only when that prose is newly attributable to this turn) | Incoming prose |
| `tool` | `NormalizedEventKind.toolUse` | Monospace one-liner: `Read PaneInfo.swift` |
| `status` | Rolled-up `AgentStatus` actually changes | Center chip: `Running → Idle` |
| `decision` | `.question` / `.suggest` | Card (may reuse existing Gateway decision path) |
| `notice` | `.notification` / error-level noise worth keeping | Secondary line |

### Example frames

```json
{"seq": 42, "pane_id": "…", "pane_session_key": "…", "kind": "tool",
 "tool": "Read", "detail": "PaneInfo.swift", "is_error": false, "ts": 1726500000.0}

{"seq": 43, "pane_id": "…", "kind": "assistant",
 "text": "Pairing uses an 8-digit code…", "ts": 1726500001.0}

{"seq": 44, "pane_id": "…", "kind": "status",
 "status": "Idle", "old_status": "Running", "ts": 1726500001.1}
```

### Coalescing

When `coalesce_tools` is true (default): consecutive `tool` items with the same `tool` + `detail` + `is_error` collapse to one entry (optional `count`). Prevents `Shell` spam from flooding the ring and the phone.

Status chips emit only on real status edges (same rule as notifications: no 2s poll noise).

---

## 3. Projector and hub

### `PaneMessageProjector`

Pure function:

```
(old PaneInfo?, IngestOutcome, MessageConfig) → [MessageEvent]
```

- Reads typed fields from the outcome / event kind; does **not** scrape viewport text unless `screen_fallback` is enabled for that agent (default **false**).
- Maps tool detail via `MessageConfig` (see §4), falling back to existing `ActivityEventExtractor` behavior when config is absent.
- Assistant emission is gated the same way `AgentRegistry.event(from:)` already gates `final_message` (`isCompletionSignal` + non-empty prose) so stale `lastAssistantMessage` does not re-enter the stream.

### `MessageStreamHub`

- Per-pane ring buffer (target **50–100** events; exact constant chosen in implementation).
- Monotonic `seq` (can share or sit beside `IngestOutcome.seq`; must be replayable).
- Subscribe API for Gateway sessions and control-socket clients.
- On pane unregister / destroy: drop that pane’s ring.

No disk persistence in v1.

---

## 4. Per-agent `message` config

Status detection keeps using the existing Manifest rules (`Resources/Manifests/*.json`, override `~/.config/seahelm/agents/<id>.json`). MessageStream adds an **optional** sibling object — not a second regex engine.

```json
{
  "id": "cursor",
  "message": {
    "assistant_from": "stop_last_assistant_message",
    "user_fields": ["prompt", "message"],
    "tool_detail_keys": {
      "Read": ["file_path", "path"],
      "Shell": ["command"],
      "Grep": ["pattern"]
    },
    "tool_aliases": { "run_terminal_cmd": "Shell" },
    "coalesce_tools": true,
    "screen_fallback": false
  }
}
```

| Field | Meaning |
|---|---|
| `assistant_from` | Where assistant prose is trusted from (v1: stop / noteAssistant path only) |
| `user_fields` | Ordered keys to read user text from hook payloads |
| `tool_detail_keys` | Per tool-name keys to format `detail` |
| `tool_aliases` | Normalize vendor tool names to display names |
| `coalesce_tools` | Merge consecutive identical tools |
| `screen_fallback` | If true, allow a degraded `notice`/`assistant` from `last_message` when hooks are absent — **off by default** |

Missing `message` block ⇒ built-in defaults (current Claude/Codex-oriented extractor behavior). Hook adapters in `HookDecoder` / `WebhookEvent` remain the place that normalizes event *types*; JSON only tunes presentation and fallback policy.

**Explicitly not in this JSON:** viewport matchers for reconstructing chat. That stays the status Manifest’s job, and MessageStream does not depend on it for the happy path.

---

## 5. Control / Gateway API

| Method / notify | Role |
|---|---|
| `message.snapshot` | `{ pane_id? }` → recent ring (one pane or all) |
| `message.subscribe` (control socket) / Gateway push | Incremental `pane.message` frames after auth |
| Existing `session.snapshot` | Unchanged for list rows: status + short preview (preview may be last stream item’s summary) |
| `pane.vt_open` | Unchanged; opt-in from UI |

Gateway already prioritizes decision frames over VT. `pane.message` frames are control-class (high priority), still tiny compared to VT.

Auth, pairing, and tunnel remain as in `2026-08-10-web-host-gateway-design.md` and the 8-digit pair flow.

---

## 6. seahelm-web interaction

**Narrow / phone default**

1. Fleet list (status dots, project, one-line preview).
2. Global / dock decision cards (keep current suggest dock behavior).
3. Pane detail = MessageStream timeline + composer (`pane.send_text` / Enter·Esc via `pane.send_keys`).
4. Explicit control: “Open terminal” → `pane.vt_open` (warn on poor network if desired).

**Wide desktop browser**

- May keep today’s VT-first layout, or default to text with VT available — implementation plan chooses one; phone path must not require VT.

**Push**

- iOS PWA push remains weak; Telegram (or system banners via Mac) stay the “something needs you” bell. MessageStream is the surface once the user opens the page.

---

## 7. Testing

- Unit: `PaneMessageProjector` — user / tool / assistant / status edges; coalesce; no duplicate assistant without completion; `screen_fallback` off ignores scan soup.
- Unit: Manifest decode of optional `message` block (absent = defaults).
- Integration: Gateway session receives `pane.message` without opening VT; snapshot replay after reconnect.
- Manual: Tailscale phone open → timeline updates while agent runs tools; approve decision card; send text; optional VT still works.

---

## 8. Rollout sketch

1. Projector + hub + control/Gateway wire (no UI change).
2. seahelm-web text-mode pane view behind a flag / narrow breakpoint default.
3. Bundle `message` defaults for `claude` / `codex` / `cursor` as needed; document override path.
4. Remove reliance on browser-side `last_message` heuristics for the default phone path.

---

## Related

- `docs/superpowers/specs/2026-08-10-web-host-gateway-design.md` — Gateway + VT production path  
- `docs/superpowers/specs/2026-08-29-seahelm-web-poor-network-design.md` — VT mitigation (complementary, not replaced)  
- `clients/seahelm-web/README.md` — current Gateway-first client  
- `Sources/Core/ChatProgressReporter.swift` — existing tool-progress projection for chat  
- Live prototype (ephemeral): `.playwright-mcp/agent-registry-text-mode.html` — shows wire gap before MessageStream  
