# Cards and First Mate in seahelm-core

Status: phase 1 (cards in the core, GPUI card strip) done; phases 2–4 planned. Decided 2026-11-04: seahelm-core owns First Mate, and every
"something waits on you" item is one card model, served by the core. The
macOS island, Telegram, seahelm-web and the GPUI client are renderers.

## Why

The GPUI client (Windows, Linux, and macOS side by side with the app) has no
island, and First Mate does not exist outside the Swift app: the coordinator,
the policy gate, the cards and `autopilot.state` / `answer` / `propose` all
live on the app's control socket. A client cannot render what it cannot get.

## What exists today (app)

There is already a single queue: `PendingOrdersQueue` holds every card,
keyed `worktree#kind[#pane][#payload]`.

| Card | Raised by | Answered by |
| --- | --- | --- |
| Agent question (AskUserQuestion) | `.question` hook event | arrow keys + Return in the dialog; multi-select ticks; follow-up questions; review page confirm |
| Screen choice (permission prompt) | `.question` from the viewport scan | arrow keys relative to the selected row |
| Suggestion (`seahelm-suggest`) | `.suggest` event | the option typed into the pane + Enter |
| Integration report | `/integrate` | "discard" runs integration again, anything else clears |
| First Mate approval | `AutopilotCoordinator.gate` (`ask`) | approve runs the held call, reject tells First Mate |
| First Mate proposal | `seahelm propose` | the option's action runs as approved; "Not now" runs nothing |

Cards are cleared when: the user prompts (suggestion), the agent uses a tool
or stops (question), the screen no longer shows a choice (screen choice), the
pane exits or closes (all of its cards), the worktree is deleted (all of its
cards).

The older green-zone actions of `FirstMate.evaluate` (`watchWaiting`,
`watchError`, `inspect`, `autoCommit`) are notifications and side effects, not
cards. The core already raises the notifications (`pane.notice`).

So "one card model" is mostly the shape the app already has. The work is
moving it, and First Mate with it, into the core.

## Card model (core)

```json
{
  "id": "c-42",
  "kind": "question | choice | suggestion | report | approval | proposal",
  "pane": "<seahelmd session>",          // empty for worktree/app cards
  "worktree_path": "/w/feat-x",
  "message": "Where should daily check-in happen?",
  "options": ["Morning", "Evening"],
  "multi_select": false, "checked": [],
  "step": [1, 3],                          // question i of n, when > 1
  "created_at": 1730700000.0,
  "updated_at": 1730700000.0
}
```

Ids are opaque and minted by the core; the dedupe key stays the app's
(`worktree#kind#pane`) so a newer suggestion from a pane replaces its older
one in place. `updated_at` moves when what the card shows moves, which is what
a renderer needs to decide whether to pop again (the app's
`SuggestionSeenSet`).

RPC on `core.sock`:

- `cards.list` → `{cards: [...]}`, oldest first.
- `cards.answer {id, option}` → `{ok}`; the core performs the answer.
- `cards.dismiss {id}` → `{ok}`; drops it without acting (proposal: "Not now").
- `events.subscribe` gains `cards.changed` (the full list, small) so
  renderers never poll.

The core performs every answer itself, through `seahelmd send`: a renderer
never presses keys. That is what makes four renderers safe: a card answered on
the phone is gone from the island in the same event, and a stale tap names an
id that no longer exists.

## First Mate in the core

Ported from `Sources/Core/Autopilot/` and `Sources/App/AutopilotCoordinator.swift`:

- `.seahelm/automations.yml` (`AutomationConfig`, built-in `fix-ci` /
  `cleanup-merged` / `triage-issues`), `CronSchedule`, `AutopilotEngine`,
  `PREventDetector`, `AutopilotLedger`, `AutopilotAudit`, `AutopilotPolicy`,
  `WorktreeFacts`. Same files on disk (`~/.config/seahelm/first-mate/`), so
  the ledger and audit carry over.
- Triggers come from the core's own PR poller (`pr.rs`) and a minute timer.
- The session is the seahelmd session `seahelm-first-mate`, launched by the
  core (`seahelmd new`), which also writes First Mate's `CLAUDE.md` and
  permission allowlist.
- First Mate's CLI calls reach the core, which gates them: reads open,
  `pane.run` / `send_text` / `send_keys` (message_pane), `worktree.create`
  (start_agent), `worktree.delete` (delete_worktree). The core executes those
  three itself (seahelmd and git); everything else is refused. An `ask`
  becomes an `approval` card.
- `autopilot.state`, `autopilot.answer`, `autopilot.propose` move to the core
  unchanged in shape; `autopilot.answer` is `cards.answer` by another name.
- Config: `autopilot_*` keys stay in `config.json`, read by the core.

### One owner

Two First Mates would handle every CI failure twice. The core takes a lease
(`~/.config/seahelm/first-mate/owner.lock`, flock / `LockFileEx`) for as long
as it runs First Mate. The app, when it sees a core that answers
`autopilot.state` with `owner: "core"`, runs no coordinator of its own and
renders the core's state and cards. An app without a core (older core, core
not running) keeps its own First Mate, as today.

## Phases (one PR each)

1. **Cards in the core.** Model, queue, producers (question, choice,
   suggestion) and clearing rules from `FirstMateCoordinator`, the answer
   paths (arrows, multi-select, follow-ups, review confirm, typed option),
   `cards.*` RPC and `cards.changed`. GPUI: a card strip above the focused
   pane plus a count on fleet rows. Rust tests ported from the Swift ones
   (`PendingOrdersQueueTests`, `SuggestionSeenSet`, question answering).
2. **First Mate in the core.** Rules, engine, ledger, audit, cron, policy,
   session, the three executed actions, approval/proposal cards, the lease,
   `autopilot.*` RPC.
3. **The app renders the core.** When the core owns First Mate and answers
   `cards.list`, the island, the dock, Telegram cards and the gateway read
   cards from the core and answer through it; `PendingOrdersQueue` becomes a
   mirror. Integration reports stay app-raised but go into the core's queue
   (`cards.raise`, app only).
4. **GPUI First Mate.** The ⎈ dock row at the foot of the fleet (state
   colour, amber with a count), First Mate's pane in the focus area with its
   cards above the terminal, number keys 1–9 to answer, Esc for "Not now"; an
   OS notification points at a new card but never answers it.
