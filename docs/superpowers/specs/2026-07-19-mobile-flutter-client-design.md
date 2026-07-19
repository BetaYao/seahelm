# Mobile Client (Flutter) — direction

**Date:** 2026-07-19  
**Status:** Direction approved (prototype v4) — **not** an implementation plan  
**Depends on:** [`2026-07-19-multiplatform-host-design.md`](2026-07-19-multiplatform-host-design.md) (H0 Host / `seahelmd`)  
**Prototype:** `.superpowers/brainstorm/*/flutter-cockpit-v4-tabs.html` (brainstorm companion)

## Problem

Ship iOS and Android in the **same milestone** as a thin remote client of
`seahelmd`: pair to a host, supervise agents (First Mate), open a pane, pick
suggestions, and later send prompts when control tier is enabled.

## Decisions (locked)

| Topic | Choice |
|---|---|
| Stack | **Flutter** (single codebase, iOS + Android) |
| Ship cadence | Both platforms in one milestone (not iOS-first) |
| Talks to | **`seahelmd` only** (never the desktop App process) |
| Capability v1 | Interactive tier (observe + `suggest.pick` / `question.answer`) |
| List density | **Compact tree** (no card chrome on First Mate) |
| First Mate tabs | **All** + **Orders** only — no separate Watch tab |
| Watch semantics | Merged into **All** (status dots + summary prefixes) |
| Hierarchy | **Repo → Worktree → Pane** (two levels under repo) |
| Pane page | Output / final message + suggest buttons + **prompt composer** |
| Prompt send | UI present in v1; **wire send when control tier** is granted |

## Non-goals (M1)

- Embedding a real terminal emulator / Ghostty on device.
- Status detection on the phone (Host/App decide; phone displays).
- Separate Watch tab or card-heavy First Mate list.
- ESP32, MQTT, or Windows UI (other tracks).

## Information architecture

Three primary screens:

```
[1 Pairing] ──► [2 First Mate] ──► [3 Pane]
                     │ All | Orders
                     │ Repo
                     │  └─ Worktree
                     │       └─ Pane rows  ──tap──► [3]
```

### 1. Pairing

- Scan desktop QR (LAN URL / host + short-lived secret) → long-lived interactive token.
- Manual host + token fallback.
- Token / known hosts in secure storage.

### 2. First Mate

**Tabs**

| Tab | Content |
|---|---|
| **All** | Full Repo → Worktree → Pane tree. Former Watch items appear here as elevated status (e.g. waiting/error dots and `Waiting ·` / `Error ·` summary prefixes), not a second feed. |
| **Orders** | Pending First Mate orders (approve / dismiss / inspect). Badge count on the tab. |

**List (compact)**

- Repo header row (name + worktree count).
- Worktree row: chevron, aggregate status dot, branch/name, pane count.
- Pane rows (indented): status dot, pane id, one-line message, agent type.
- No card backgrounds / heavy containers.

### 3. Pane

- Header: back, pane id, status, worktree + repo + agent.
- Output / final message region (push fields from Host; optional capped `pane.read` later).
- Suggest / question option buttons (interactive tier).
- Bottom **prompt composer** + send control.
  - Interactive-only tokens: composer may be visible but send gated (or clearly disabled) until control tier.
  - Future control tier: `pane.send_text` / equivalent via `seahelmd`.

## Client architecture (Flutter)

```
ui/          Pairing, FirstMate (All/Orders), Pane
domain/      Repo / Worktree / Pane / Order models, session
srp/         WSS JSON-RPC client, auth, seq resume, reconnect
storage/     token, hosts
```

UI never owns the socket; Domain merges snapshot + events into the tree.

## Alignment with Host doc

- Pairing, interactive tier, final message push, capped `pane.read`: Host design §§4–7.
- Prompt send is **control-tier** on the wire; M1 may ship composer UI ahead of granting that capability.
- H0 success still uses a script client; M1 is the product Flutter apps.

## Open points (for M1 implementation plan)

1. All-list sort (e.g. waiting/error first) — not locked; default = host order / recent activity.
2. Worktree collapse/expand persistence.
3. Orders actions mapping to exact SRP / Backend methods.
4. Repo layout: monorepo path vs `project` field from snapshot.
5. Flutter package location (`mobile/` in seahelm vs separate repo).

## Success criteria (M1)

- Same Flutter app builds for iOS and Android.
- User pairs via QR (or manual), sees All tree Repo→WT→Pane with watch-like status fused in.
- Orders tab shows pending items with approve/dismiss.
- Opening a pane shows final message / output excerpt, can pick suggest options, sees prompt field (send when control allowed).
