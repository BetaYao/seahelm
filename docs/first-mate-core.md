# Cards and First Mate in seahelm-core

Status: phases 1 (cards in the core, GPUI card strip), 2 (First Mate in the core), 3 (the app follows the core's First Mate) and 4 (the GPUI workbench) done. Decided 2026-11-04: seahelm-core owns First Mate, and every
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

## As built (phase 2)

- `seahelmd/crates/core/src/first_mate/`: `rules` (automations.yml, built-ins,
  quiet hours, branch globs), `cron`, `clock` (local time from the system
  offset), `engine` (PR edge detector, ledger, dispatch and prompt, audit),
  `facts`, `policy`, `pane` (directory, managed files, launch), and `mod.rs`,
  the coordinator: one thread that owns all First Mate state and is talked to
  by message (gate / propose / state / say wait for an answer; pane outcomes
  and answered cards do not), ticking every 20 s for config, session, PRs,
  schedules and delivery.
- Ownership: the core runs First Mate only with `autopilot_enabled: true`
  **and** `autopilot_owner: "core"` in `config.json`, and only while it holds
  `first-mate/owner.lock` (`File::try_lock`). Without `autopilot_owner` the
  app keeps First Mate as before, so this phase changes nothing until the
  key is set. Turning it off stops First Mate within a tick and drops its
  open cards; the session is left, as the app leaves it.
- The CLI: First Mate's directory gets `bin/seahelm` (`seahelm.cmd` on
  Windows), a shim onto `seahelm-core cli`, put first on its PATH inside the
  session's shell. Verbs: `pane list/read/run/send/keys/wait`, `worktree
  create/delete`, `propose --json`, `cards`. Every call carries
  `_meta.caller = $SEAHELM_PANE_ID`, which the core gates on, as the app did.
- The core performs the gated actions itself (`actions.rs`): `pane.read`,
  `pane.run`, `pane.send_text`, `pane.send_keys`, `worktree.create` (the
  app's `task/<slug>` branch beside the repo in `<repo>-worktrees/`, setup
  hook first, the agent briefed by its positional prompt, `agent_yolo`
  honoured, in a held seahelmd session named as the GPUI client names a
  worktree's first pane so it attaches to it) and `worktree.delete` (sessions
  killed, `git worktree remove` without force, branch kept).
- Approval and proposal cards are raised in First Mate's directory with the
  approval id as payload; `card.answered` (and `cards.dismiss`) reach the
  coordinator, which runs the call off its thread and tells First Mate.
- `autopilot.state`, `autopilot.propose`, `autopilot.answer {card, option}`
  and `autopilot.say {text}` on the core socket.
- First Mate's pane gets no notices; its own questions still become cards.

## As built (phase 3)

- Settings ▸ First Mate ▸ "Run in seahelm-core" writes `autopilot_owner:
  "core"`. With it, `AutopilotCoordinator` stops its own First Mate and
  follows the core's: every 2 s it reads `autopilot.state` over
  `core.sock` (`CoreSocketClient`) and mirrors First Mate's approval and
  proposal cards into `PendingOrdersQueue` by their ids, so the island,
  the dock, Telegram cards and seahelm-web show them unchanged; answering
  or dismissing one goes to `autopilot.answer`. Chat to First Mate goes to
  `autopilot.say`; its answers still return to the chat that asked (the app
  watches First Mate's pane as before). The Telegram line for each action
  comes from reading the core's `audit.jsonl` where the app left off.
- First Mate's view attaches to the core's session and never creates or
  replaces it.
- Handover: the core stamps its session `<version>:<agent>:core`, the app
  `<version>:<agent>`, so whichever takes First Mate over replaces the
  other's session (the app's has no `seahelm` shim on its PATH). First
  Mate's conversation restarts; its rules, ledger, audit and standing
  orders carry over.
- Scope: only First Mate's cards come from the core so far. Agent questions
  and suggestions stay the app's own until the app takes its statuses from
  the core (a separate plan); integration reports likewise.
## As built (phase 4, GPUI)

The surfaces design (`docs/superpowers/specs/2026-11-04-first-mate-surfaces-design.md`)
states 1 and 4 for GPUI:

- The fleet column's foot is First Mate's dock (it replaces the usage strip):
  ⎈, its state (from `autopilot.state`; "In the macOS app" when the core
  does not own it but the session is up, "Core offline" without a core),
  the 5h usage per provider, and how many cards wait.
- Clicking it puts the workbench in the main area: First Mate's real
  terminal on the left (attached only once `seahelm-first-mate` exists,
  never created from here; an empty state says why it is not there), every
  card on the right in its own scrolling column, each naming its project and
  worktree. No second chat input: the terminal is the conversation.
- A card is not done when clicked: it shows "Sending…" until the core takes
  it off the list (`cards.changed`), and a failure stays on the card with
  the reason ("Already answered elsewhere" for a stale id) to try again.
  Without a core nothing can be answered.
- The header's × or picking any worktree closes the workbench; First Mate's
  session keeps running. Esc stays with the terminal.
- Not yet: a draggable divider between the two columns (the card column is a
  fixed 340pt).
## Message timelines in the core

What Island's First Mate conversation (surfaces design, state 3) and
seahelm-web's Timeline draw, moved into the core (`crates/core-messages`),
ported from `MessageEvent`, `PaneMessageProjector`, `MessageStreamHub` /
`MessageStreamStore` and `AgentTranscriptTail`:

- Each outcome the registry makes is projected into rows (user prompt, tool,
  decision, notice, turn edge, the turn's final message), with the app's
  coalescing; the prose an agent writes between tool calls is read from its
  transcript (path from the hook) without the core's lock, and put on the
  timeline before that hook's own rows.
- A ring of 80 rows per pane in memory; history on disk, one JSONL file per
  pane in `~/.config/seahelm/core-message-stream/` (the app keeps its own in
  `message-stream/` while both run), trimmed to 2000. Sequence numbers are
  global and survive restarts. A closed pane's history goes.
- `message.snapshot {pane_id?}`, `message.history {pane_session_key | pane_id,
  before_seq, limit}` (the app's shapes) and `message.subscribe {pane_id?,
  after_seq?}`: a stream of its own, not `events.subscribe`, so a busy
  pane's tool rows never push status events out of that ring. Reconnecting
  with `after_seq` gets only what came after; `reset` when the client is
  ahead of the core, `truncated` for rings that may have lost part of the gap.
- `seahelm-core compare-messages` lines the app's timelines up against the
  core's for the same panes (shadow mode) and logs what only one side has to
  `core-messages-shadow.jsonl`.

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

## The core and the gateway

Decided 2026-11-04; drawn in `docs/target-architecture.html`.

**The core says what is true and what may be done; the gateway says who is
asking and how to talk to them.** The core gives every caller the same
answer, trusts only its local socket (0600) and touches no network. The
gateway is the only network-facing piece — identity, transport, each
channel's presentation — and to the core it is one more client: it uses
the public interface only (`core.sock` calls and `events.subscribe`,
`message.subscribe`, `cards.changed`, plus seahelmd's session sockets for
terminal streams), never the core's files, never the app.

Where something goes:

1. A second channel (Slack, mail) would need it unchanged → the core. Tied
   to one channel's protocol → the gateway.
2. It holds credentials or trust towards the outside world → the gateway.
3. Every surface must see the same result → the core.

| The core | The gateway |
| --- | --- |
| Agent status, PRs, usage | Auth: pairing codes, tokens, Telegram initData, `allowed_users`, the Mini App host, share links |
| Cards: raising, performing answers, staleness | Connections: WebSocket, reconnects, each client's replay cursor |
| Message timelines | Terminal streams: straight from seahelmd, not through the core |
| First Mate: session, gate, approvals, proposals, `say` | Telegram: long poll, formatting, chunking, media, rate limits |
| Whether to notify | Where a notice goes: which chat, the default chat, muting |
| Pane and worktree actions, waits | Channel presentation: buttons ↔ card ids, progress drafts, groups vs private chats |
| Stable pane handles (`#n`), parsing and running text commands | Chat bindings: which chat is talking to which pane |
| | Channel secrets: bot token, pairing secret, in the gateway's own config |

The grey areas, settled:

1. **The command language** (`/go #3`, `/order`, `@worktree`) is parsed and
   run by the core behind one call, text plus context (the pane a chat is
   bound to); the island's command line, Telegram and mail share it, and the
   handles mean the same everywhere. The binding itself is the gateway's
   conversation state, passed in as context.
2. **Talking to First Mate from Telegram**: the core never sees chat ids. The
   gateway notes which chat asked when it calls `autopilot.say`, follows
   First Mate's message stream, and sends the answer back when the turn
   ends. (In the app this is `AutopilotCoordinator`'s reply targets; it moves
   to the gateway.)
3. **Messages from senders who may not command** (a monitoring channel) are
   recognised and parsed by the gateway; whatever they trigger goes through
   the core's business calls and the same gate.
4. **Who answered a card**: authorisation happens only in the gateway. Its
   calls carry `_meta.via` (`telegram:@name`), which the core writes to the
   audit and never authorises on.
5. **Configuration and secrets**: the bot token, `host_gateway` and the
   pairing secret move to the gateway's own config file instead of sharing
   `config.json` with the app's settings (which is how they kept being
   dropped by a settings save).

Still to build for this boundary: the core's text-command call (the command
language is the app's today: `CommandParser`, `CommandExecutor`,
`PaneHandleRegistry`), and the gateway itself with its own config.
