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

### Why not keep `AgentRegistry` and change its writer

The first cut did exactly that (an adapter: core outcomes rebuilt into
`NormalizedEvent` / `IngestOutcome` and pushed down the old funnel). It
worked, but it kept the boundary blurred: the app still carried a full
decision engine switched off by flags, `NormalizedEvent` meant "input to a
decider" in the core and "output of one" in the app, and the card queue
mixed the core's cards with the app's by id prefix. With no compatibility
to keep, the app gets a shape of its own instead.

### The boundary

**seahelm-core decides; the app shows, lays out and delivers.** Anything that
answers "what is this agent doing, and what should the user hear about it"
lives in the core and nowhere else.

| | seahelm-core | macOS app |
|---|---|---|
| Hooks | the only receiver (`seahelm-hook` → `core.sock` only) | none |
| Screen, OSC 7501 | reads from seahelmd | draws; keeps nothing for status |
| Status, unseen, notices | decides, pushes | reports what it shows (`client.visible`, `pane.seen`); presents notices |
| Cards | the only queue: agent cards, and cards a client raises (`cards.raise`) | renders the queue; answers and dismisses through the core; acts on `card.answered` for cards it raised |
| Message timelines | keeps, serves | renders |
| Locations | decides, pushes `pane.location` | acts on it (fork, auto-fork, repo auto-add) |
| First Mate | the only owner | renders its conversation and cards |
| PR, usage | fetches, serves | renders |
| Layout, panes, sessions | told by the app (`pane.sync`, `worktrees.set`) | owns |

### The app's side

- **`CoreClient`**: the app's one connection to the core: calls, plus one
  event stream with typed events (`PaneUpdate`, `Notice`, `CardsChanged`,
  `CardAnswered`, `LocationChanged`, `Unseen`). Reconnects, and replays
  `pane.list {detail: true}` and `cards.list` on every connect.
- **`Fleet`**: a read model of the core's panes, keyed by seahelmd session
  name: `PaneState` is exactly the core's `pane_detail`. It is written only
  by `CoreClient` and has no logic beyond lookup and change observers. It
  replaces `AgentRegistry`'s state half. Rows, the island, chrome, the
  control socket and the web read it.
- **`ChannelHub`**: Telegram, mail and chat routing, pulled out of
  `AgentRegistry` (where it has nothing to do with agent state). It reads
  `Fleet` and `CoreClient` events like any other consumer, until it moves to
  seahelm-gateway.
- **`NotificationPresenter`**: banner and history for a core `Notice`. No
  cooldowns, no gates.
- **Cards**: no app queue. The island, Telegram and the web render the
  core's cards. The app's own asks (integration reports) are raised with
  `cards.raise`, and their answers come back as `card.answered`.
- **Deleted** with `AgentRegistry`: `StatusPublisher`, `StatusDetector`,
  the manifest engine, decoders, `WebhookStatusProvider`, `HookDecoder`,
  `NormalizedEvent`, `IngestOutcome`, `PaneReducer`, `NotificationManager`'s
  decisions, `PendingOrdersQueue`, `MessageStreamHub`,
  `PaneMessageProjector`, the app's First Mate host (`AutopilotCoordinator`'s
  local mode, `FirstMateCoordinator`, `FirstMate.evaluate`), and the app's
  hook sink on the control socket.

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

Each step deletes what it replaces in the same change. Old sessions (a
seahelmd from before `Snapshot`) were restarted on 2026-11-04.

| | Scope |
|---|---|
| 1 | Core: the whole pane on the wire (`pane_detail`), `pane.location` pushed, aliases updated on `pane.sync`, visibility kept per client. **Done.** |
| 2 | Core: the only hook receiver (`seahelm-hook` v8 sends to `core.sock` only) and the only First Mate owner (no `autopilot_owner`; the app's First Mate host goes). |
| 3 | App: `CoreClient` and `Fleet`. Every reader of `AgentRegistry` moves to `Fleet`; `ChannelHub` takes the channel half. `AgentRegistry`, the scan, the hook sink and every decider listed above are deleted. |
| 4 | App: notices through `NotificationPresenter`; unseen from `Fleet`. |
| 5 | App: cards from the core only; integration reports raised with `cards.raise`. `PendingOrdersQueue` goes. |
| 6 | App: timelines from `message.*`; `MessageStreamHub` goes. |
| 7 | App: fork, auto-fork and repo auto-add on `pane.location`. |
| 8 | App: PR and usage from `pr.list` / `usage.summary`; the GitHub poller, usage providers and the `CommandExecutor` fallback go. |

Steps 3–5 land together: `Fleet` replacing `AgentRegistry` takes the
outcome stream that notices and cards rode on. 6–8 are independent.

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
