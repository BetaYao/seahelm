# The macOS app as a client of seahelm-core

Status: plan, 2026-11-04. A hard cut: no switch, no shadow phase, no
fallback, no compatibility with old sessions.

## Goal

The app stops deciding what its agents are doing. seahelm-core decides
status, completions, notices, cards, message timelines, locations, PR state
and usage for every client, and the app draws them. After this, the app and
the GPUI client read the same answers, and about 6–7k lines of Swift that
duplicate the core are gone.

What stays in the app: Ghostty surfaces and input, layout and panes, drawing
(colours, rows, island), delivering a notification the core decided on, the
control socket for the `seahelm` CLI, and acting on what the core reports
(fork, auto-fork, repo auto-add) until those actions move into the core too.

## Where it stands

- The core decides status for the app's panes in shadow. It agreed on 99.8%
  of pane-polls over six hours on 2026-11-04. Every disagreement that lasted
  more than a few seconds was on a pane whose seahelmd predates `Snapshot`
  (2026-11-03 23:33). On those panes the core cannot see Claude's OSC 7501
  record, while the app reads it straight from Ghostty.
- The core already serves cards, notices, unseen completion, message
  timelines, locations (by polling), `pr.list`, `usage.summary` and the
  command language. The app already uses the command language.

## The seam

Every status change in the app goes through one funnel:

```
StatusPublisher (screen)      ─┐
WebhookStatusProvider (hooks) ─┼─► AgentRegistry.ingest ─► arbitration ─► onOutcome ─► consumers
GhosttyBridge (OSC 7501)      ─┘
```

`TabCoordinator`'s `onOutcome` fans out to First Mate, integration, mail,
chat progress, completion delivery, the worktree aggregator and the title
bar. Everything else reads `AgentRegistry.shared` directly: the island, the
web gateway, `pane.list` on the control socket, Telegram, and `EventHub`.

`AgentRegistry` stays as the app's local model; only its writer changes. A
new `CoreStatusFeed` follows the core's `events.subscribe` and writes each
core outcome into the registry as an already-decided snapshot
(`AgentRegistry.apply(decided)`: set the fields, publish the outcome, no
arbitration). The three producers are deleted. Consumers keep reading the
registry, so most of them do not change.

```
seahelm-core ─ events.subscribe ─► CoreStatusFeed ─► AgentRegistry.apply(decided) ─► onOutcome ─► consumers
```

## What the core adds first

1. **The whole pane on the wire.** `pane.list` carries only `status`,
   `last_message`, `title` and `unseen`, but the app draws more:
   `last_assistant_message`, `last_user_prompt` (and both `_at`),
   `command_line`, `round_duration`, `started_at`, `tasks`,
   `activity_events`, `background_busy`, and the three source statuses. The
   core's `PaneInfo` has every one of them already. Add `pane.list {detail:
   true}`, and an `info` object with the same fields on
   `pane.status_changed` / `pane.updated`, so one event updates a row with no
   second call.
2. **Locations pushed.** The core keeps each pane's work location
   (`pane.locations`) but sends no event when one changes. Add
   `pane.location {pane, worktree, location, created_by_agent}`, which the
   app's fork and auto-fork act on.

## Steps

Each step replaces the app's code and deletes the old path in the same PR.
Old sessions (a seahelmd from before `Snapshot`) are restarted once before
step 2 ships: the core cannot get their OSC 7501 records, and nothing
bridges that.

| | Scope |
|---|---|
| 1 | Core: the whole pane on the wire, and `pane.location` pushed, with tests. |
| 2 | Status. `CoreStatusFeed` writes the registry, replaying `pane.list {detail: true}` on every (re)connect. Deleted: `StatusPublisher`, `StatusDetector`, the manifest engine and store, the decoders, `WebhookStatusProvider`'s status path, the 7501 ingest, and the registry's arbitration, grace and reclaim. The hook bridge goes core-only (`seahelm-hook` v8), and the control socket stops taking `hook` / `suggest`. The shadow comparator goes. |
| 3 | Notices and unseen completion. The app reports `client.visible` and `pane.seen`; `deliverAgentCompletion` fires on `pane.notice`; `unseen_completion` comes with the pane. `NotificationManager` keeps delivery only. |
| 4 | Cards. The island, Telegram and the web read `cards.list` / `cards.changed` and answer with `cards.answer` / `cards.dismiss`; the app raises its own reports with `cards.raise`. `PendingOrdersQueue` goes. |
| 5 | Messages. The web gateway, Telegram and the island read `message.*`. `MessageStreamHub` goes. |
| 6 | Locations. Fork, auto-fork and repo auto-add act on `pane.location`. |
| 7 | PR and usage. The app reads `pr.list` and `usage.summary`; its GitHub poller and usage providers go. The `CommandExecutor` fallback goes. |

Steps 3–7 depend only on 2.

## When the core is not there

The app ensures the core every 2 s (`CoreLink`) and does nothing else.
While the core is down, the fleet shows "core unavailable" instead of
stale statuses, and comes back by itself on reconnect.

## What goes, in total

| | Lines |
|---|---|
| `Sources/Status/` (screen scan, manifests, decoders, `WebhookStatusProvider`, notification decisions, debounce, aggregator inputs) | ~5,000 |
| `AgentRegistry` arbitration, grace and reclaim, unseen marking | ~600 of 1,471 |
| `MessageStreamHub` | 305 |
| `PendingOrdersQueue` | 236 |
| `WorktreePRStore` and parser | 245 |
| `Sources/Usage/` providers | ~700 of 874 |
| `CommandExecutor` fallback (`Sources/Core/Command/`) | to be counted |
| The shadow comparator, `compare-messages`, `scripts/ab/` | Rust and scripts |

The manifests (`Sources/Status/Manifests/*.json`) live in the core's tree
from then on. User overrides in `~/.config/seahelm/agents/` keep working,
read by the core.

## Risks

- **One process to trust.** A core bug shows in every client at once, with
  nothing to fall back to. The core's decisions are logged
  (`core-events.jsonl`), and `pane.explain` says why it decided.
- **Latency.** Hook-driven changes reach the app one socket hop later than
  today. Screen-driven ones change from the app's poll to the core's, both
  every 2 s. Budget 100 ms at p95; measure it in step 2.
- **First Mate.** The app filters First Mate out of the fleet by worktree
  path. The feed has to keep doing that, whichever side owns First Mate.
- **Pane identity.** The core keys panes by seahelmd session name, the app
  by `Station.id`, which the core holds as an alias. A pane whose session is
  replaced (recovery, fork) has to re-register before its events can be
  mapped. Step 2 is checked with a recovery and a fork.
