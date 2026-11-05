# First Mate autonomy: learning to take over the chores

Status: phases 1–9 built (2026-11-05).
Builds on `docs/first-mate-core.md` (First Mate lives in seahelm-core) and
`docs/superpowers/specs/2026-11-04-first-mate-surfaces-design.md` (the island).

## What the user wants

First Mate should, as its name says, decide some things on its own. Three
traits, in the user's words:

1. **It handles chores for me.**
2. **It learns from what I do** — my operations and my conversations.
3. **It does not interrupt too much.**

And the shape: on a fresh install First Mate knows almost nothing about *this*
user. It watches, writes down what it learns, and takes things over one at a
time as it earns them.

Five concrete scenarios hang off that: deleting worktrees that are done with;
turning a stated requirement into a worktree in the right project; pulling
tasks from GitHub and Jira; scheduled jobs such as industry research; and
remembering each project's goal. The most painful today is **worktrees piling
up**, so that is the first vertical slice.

## Decisions

| # | Decision | Date |
|---|----------|------|
| D1 | Loosening needs one explicit yes from the user; tightening is automatic. The core enforces it, not the prompt. | 2026-11-05 |
| D2 | Worktree pile-up is the first problem to solve, and the slice that proves the learning loop. | 2026-11-05 |
| D3 | First Mate starts knowing little and learns from the user's operations and conversations, automating gradually. | 2026-11-05 |
| D4 | The built-in rules (`fix-ci`, `cleanup-merged`, `triage-issues`) stay. They are *general rules* that ship with seahelm and apply to every project; learned habits are the user's own and sit beside them. | 2026-11-05 |
| D5 | First Mate may learn from the user's conversations with agents in panes (their prompts, from the core's message timelines), accepting that First Mate reading them sends them to the model's API. | 2026-11-05 |
| D6 | One "inventory" card when First Mate is first turned on is acceptable, to give the learning a cold start. | 2026-11-05 |
| D7 | Everything First Mate learns stays on this machine: habits and project memory alike. Nothing is written into a repo. | 2026-11-05 |
| D8 | The brief has no fixed time: First Mate learns when (and where) the user picks things up and sends it then. | 2026-11-05 |
| D9 | First Mate tunes its own thresholds (N, M, card expiry, daily cap) from how the user responds, within hard bounds the core keeps. | 2026-11-05 |
| D10 | A link that identifies its project (a GitHub issue/PR URL; later a Jira key once mapped) counts as the user naming the project: First Mate starts on it without a card. | 2026-11-05 |
| D11 | The user's `autopilot_autonomy` default for an action caps habits by its value: `deny` stops every habit (even one the user approved), `ask` caps a habit the user never approved and is replaced by an approved habit's level. | 2026-11-05 |
| D12 | A habit level raised by hand in its YAML file, above what the core granted, is neither applied nor silently undone: the core raises a confirmation card (the habit, the granted level, the written level, the evidence). Yes records the written level as granted; no writes the granted level back into the file. Until the user answers, the granted level applies. | 2026-11-05 |
| D13 | One approval of a batched card counts as one approval of each habit on it, however many worktrees it covered: M approvals means M taps, not M worktrees. | 2026-11-05 |
| D14 | Only the user answers cards or speaks to First Mate as the user. The core checks who is on the other end of the socket (the kernel's peer pid, not what the call says about itself), refuses a caller inside a seahelm pane, and seals `.granted.json`. Not a sandbox: see "Who may answer a card". | 2026-11-05 |
| D15 | Presence is read from moments, never from states: keys or the mouse in a seahelm window (`client.activity`, at most once a minute from the macOS app's local `NSEvent` monitor and the GPUI client's capture listeners: that it happened, never what; no system-wide monitoring, no Accessibility permission), a desktop client coming to the front or changing what it shows while in front, the user's prompt in a pane (unless something typed into that pane within 90 s, or the same text within 30 min), a card answer, words to First Mate, a command line, typing into a pane from a chat. An app left in front overnight is not a user at the desk. The brief's day starts at 04:00 local, so a late night belongs to the day before. | 2026-11-05 |
| D16 | The brief is always written into First Mate's timeline (a `brief` row); Telegram gets it too when that is the channel. Channel order: arrived on Telegram → Telegram; a desktop client in front → the island; answered on Telegram within 14 days (and more recently than on the web) → Telegram; otherwise the timeline only. Before sending to Telegram the core asks seahelm-gateway (`gateway.status`: Telegram on, configured, connected): an arrival brief meant for Telegram goes to the timeline instead; the fallback is not sent and does not count, so it waits for the user to come back. Quiet hours are the user's own (`config.json` `first_mate_quiet_hours`, e.g. `"23:00-08:00"`) together with every known repo's `quiet_hours`. The fallback needs a learned usual start; a profile that knows nothing never falls back. The brief and the core's note rows are written in `first_mate_language` (`en`, default, or `zh`). | 2026-11-05 |
| D17 | Cards are *answering* (an approval or proposal while the user spoke this turn, the per-worktree cards after "Let me pick", a level written by hand (D12), the inventory (D6)) — up at once, never counted; *time-sensitive* (an approval for a `ci.failed` rule) — up at once whether the user is there or not, never counted, and on Telegram as it goes up (seahelm-gateway sends every First Mate card there); or *proactive* (the sweep's batch, promotion offers, any other rule's approval such as `cleanup-merged`'s, an unprompted proposal) — up only while the user is active and under the day's cap of 3, else held. The brief puts at most 3 held cards up with it, uncounted, and lists the rest in its text; those go up later by the usual rule (user active, cap left). | 2026-11-05 |
| D18 | A card expires 3 days after it went up (time held does not count). Only action cards count as unanswered evidence: an expired sweep batch or delete approval is one `ignored` for each habit it was about (a batch: once per habit on it), and two in a row demote. A promotion offer or a hand-edit confirmation (D12) that expires is only withdrawn: no `ignored`, no demotion; the offer waits for fresh evidence (like "not yet"), the confirmation is not asked again until the file says something else. Item cards, inventory cards, proposals and non-delete approvals teach no habit. A habit's automatic actions no longer ping Telegram one by one: they are the brief's. | 2026-11-05 |
| D19 | Review waits a full 24 h after enabling, then at least 24 h between deliveries, with 30 min without a presence signal. Delivery uses the existing idle/session/paused gates; no queued event is displaced. The core caps the JSON payload at 24 KB, groups worktree observations by kind, actor, PR state, risk/clean status, age buckets (0, 1–3, 4–14, 15+ days) and busy panes, ranked by count before capping, and supplies distinct days/worktrees and examples. Card outcomes are counted separately per habit; recent user/assistant messages are filtered before taking the last ten, then shown oldest first. Project prompts are filtered for programmatic echoes when ingested. Review timing persists in budget.json. | 2026-11-05 |
| D20 | `habits.propose` is a card-producing First Mate call. New habits, global or `repo` scoped, at most ask; existing ids are refused without changing level or evidence; core discards supplied evidence and grants. No habit is saved until the user answers. A prose `when` requires `judgement: true` on the proposal and persists with an explicit judgement tag; ordinary scalar conditions in habit files are refused with a note and never silently interpreted as judgement; a named habit action (`--habit`) is held at ask and must name an active granted deletion habit. Invalid measured objects are refused. | 2026-11-05 |
| D21 | Tuning lives in budget.json under first-mate, with bounded N 2–10, M 3–20, expiry 1–7 days and cap 1–5. Six consistent outcomes move a knob one step; acceptance/decline adjusts N, auto promotion acceptance/decline (including subsequent auto demotions) adjusts M, answers within an hour / after a day adjust expiry, answered/expired cards adjust cap. Dismissal supplies neither an answer nor latency, rule approvals supply response timing only, and demotion supplies promotion evidence without resetting the expired streak. Each actual move writes an audit line and one brief note; it grants no level. | 2026-11-05 |
| D22 | Core card delivery translates built-in option labels using first_mate_language. Clients answer by index or the card’s shown label, as the registry requires; island, web and Telegram currently send indices. The shown label resolves to a core-owned canonical key before any First Mate comparison. Arbitrary canonical keys and English aliases are not accepted on a Chinese card. Cards raised in English retain their own English labels across a language change. | 2026-11-05 |
| D23 | Q7: routing a request with no link or project name is a habit like any other; enough correct picks may earn auto through the usual promotion card (D1). | 2026-11-05 |
| D24 | Memory uses named topics; replacing a topic supersedes its previous active entry in place. Only a sealed core-written revision is injected; external edits require confirmation of their exact digest by the user. | 2026-11-05 |
| D25 | A mandate is measured from the user's original message, matches known project names, approved aliases or GitHub owner/repo remotes, and is consumed only on a successful creation per user turn; a further start needs a card. Explicit deny and repository policy still win. | 2026-11-05 |
| D26 | Routing observations retain the words on the card's originating turn. Routing habits retain exact normalized words; short project aliases require their own user-confirmed card; no semantic match asserted by the model grants authority. | 2026-11-05 |
| D27 | Jira supports Cloud (email + API token, HTTP basic auth, `https://<site>.atlassian.net`) and Server/Data Center (personal access token, bearer). Credentials stay in `~/.config/seahelm/first-mate/secrets.json`, mode 0600, never in config.json or a repository; only the user may write them through `seahelm task-source …`, with kernel peer checks. | 2026-11-05 |
| D28 | Task reads default to every 30 minutes per source; configurable from 5 minutes to 7 days. Each tick admits at most four due sources, each reads at most 50 issues, 100 open PRs and 100 recently updated merged PRs. Reads run off the First Mate thread, with request timeouts; failures never start work. Fetchers are injectable and tests use fakes. | 2026-11-05 |
| D29 | `task.new` is internal candidate data. Only the daily brief lists tasks in “Could do / 可以做” and may raise one proactive selection card, with at most three ranked tasks plus Pass. Its answer is permission for that one `worktree.create`; pause, deny, budgets and deduplication still apply. No task event starts work or raises a card itself. | 2026-11-05 |
| D30 | Ranking combines priority labels / Jira priority, assignment to the authenticated user, and bounded label preferences from `task.started` / `task.passed`. This is a judgement ranking habit, never an autonomy grant. Answered offers survive restart; unanswered cards become offerable again. A task on an expired card cools down for 7 days before it is offerable again; its second expiry drops it permanently, without user-pass evidence or a ranking penalty; newly assigned tasks may be offered anew; source content cannot become a memory directive. | 2026-11-05 |
| D31 | Research reports live in `~/seahelm-research`, initialized on first use and registered as an ordinary project. The brief contains only a short change summary and report path, never the full report. | 2026-11-05 |
| D32 | Global schedule mutations are user-only, peer-checked RPCs; schedule.list is read-only and available to panes. Only the exact job created through `schedule.add` has standing approval; hand edits do not grant starts. Cron fires once per matching minute, without catch-up, only while running, unpaused and outside quiet hours. `run-now` uses the same gates. | 2026-11-05 |
| D33 | Creating a schedule is the user's standing approval for that job's `start_agent`: otherwise every recurrence would ask again for an action the user explicitly scheduled. The core applies this approval only to its own exact job start, preserving deny and concurrency/usage budgets. Runtime expiry plus 30 seconds of grace or a vanished session ends the run independently of interrupt delivery. Research has a global concurrency cap of one (`MAX_RESEARCH_RUNS`); overflow is skipped and audited. Scheduled starts use `research.started` / `schedule` audit entries, collected into the brief rather than individually sent to Telegram. | 2026-11-05 |
| D34 | After three consecutive committed reports without a visible worktree visit or a follow-up to First Mate, propose stopping the job through a proactive card. Only the user's answer disables it. First Mate writes a capped change summary on `research.done`; the core stores it for the next brief. A committed report waits for an idle pane or the deadline before closing its session. Cleanup first verifies a linked worktree of the research repo (never main); integration is `--ff-only`. On failure any merge is aborted, the user gets one note and automatic cleanup stops, retaining the branch/worktree. Successful removals use `first_mate`, `how: research:<job>`. Failed runs are reported once; only reports/ and tracked changes are committed as leftovers. Untracked/ignored data is never force-added or deleted: its worktree is retained and the user is told. Launch reservations expire after 120 seconds; timeout/failure notes go to the timeline. Stop-job edits preserve unrelated schedule entries and their formatting. Finished runs retain only bounded report metadata; main is never removed. | 2026-11-05 |

## Today (verified in code, 2026-11-05)

- **Triggers**: `ci.failed`, `pr.merged`, `schedule` (cron, per repo) —
  `first_mate/engine.rs`, `mod.rs::check_schedules`. Missed minutes are not
  caught up.
- **Rules**: a repo's `.seahelm/automations.yml`, else the built-ins
  (`rules.rs::Config::built_in`): `fix-ci` (on), `cleanup-merged`
  (`delete_worktree: ask`, on), `triage-issues` (weekdays 9:00, off).
- **Actions** First Mate may request (`policy.rs::classify`): `message_pane`
  (`pane.run/send_text/send_keys`), `start_agent` (`worktree.create`),
  `delete_worktree` (`worktree.delete`), plus `autopilot.propose` cards.
  Everything else is forbidden.
- **Levels**: `auto / ask / deny`, defaults `message_pane: auto`, the other two
  `ask`; the user's `autopilot_autonomy` laid over them. `mod.rs::level` takes
  the strictest of the rules being handled, and adds the user's defaults once
  the user has spoken ("talking cannot loosen a rule"). Consequence: when the
  user *asks* First Mate to start something, `start_agent: ask` still raises an
  approval card.
- **Facts** (`facts.rs`): uncommitted files and lines, untracked files, commits
  on no remote-tracking ref, busy panes; put on events and on delete cards.
  It does **not** see gitignored files — and `git worktree remove` (no
  `--force`, `actions.rs::worktree_delete`) deletes ignored files silently. An
  `.env`, a notes file or local data in a worktree is lost without a word.
- **Unpushed** is `rev-list HEAD --not --remotes`. After a squash merge on a
  repo that deletes head branches, the branch's commits are on no
  remote-tracking ref, so a merged worktree reads as "N commits on no remote"
  even though GitHub keeps them under `refs/pull/<n>/head`. The core's PR fetch
  carries no head oid to check against.
- **Who deleted a worktree**: the core sees a worktree vanish from the app's
  2 s mirror, but not who removed it or what was in it.
- **Memory**: one global `~/.config/seahelm/first-mate/standing-orders.md`,
  updated only when the user says "remember …". Nothing per project; agents
  never see it.
- **Signals nobody collects**: card answers (approve / reject / ignored), the
  user's own deletions and creations, the user's prompts to agents
  (`core-messages`, `EventKind::UserPrompt`).

## The learning loop

Three roles, each where it is strongest:

| Step | Who | Why there |
|------|-----|-----------|
| **Record** what the user did and the state at that moment | core (deterministic) | It has to be exact; a model's recollection is not evidence. |
| **Generalise** records and conversations into a *habit* | First Mate (LLM) | Only a model can see "these seven deletions are one pattern" or turn "don't bother with docs PRs" into a rule. |
| **Apply** a habit when its situation recurs | core, by measured facts | Autonomy is enforced by code, never by a prompt. |

The constraint that holds it together: **a habit may reach `auto` only if its
condition is written in facts the core measures.** "PR merged, everything
pushed, idle three days" is measurable and can become automatic. "No longer
relevant to the project's goal" is not, and can at most reach "ask".

### Observations (core)

`~/.config/seahelm/first-mate/observations.jsonl`, append-only, one line per
thing the user (or an agent, or First Mate) did that a habit could be about:

```json
{"at":"2026-11-05T10:12:00Z","kind":"worktree.removed","repo":"/w/seahelm","worktree":"/w/seahelm-worktrees/feat/x",
 "branch":"feat/x","by":"user","facts":{"pr":"merged","days_since_merge":4,"uncommitted":0,"untracked":0,
 "ignored_files":0,"unpushed":0,"idle_days":4,"busy_panes":0}}
{"at":"…","kind":"worktree.created","repo":"/w/seahelm","branch":"fix/y","by":"user","prompt":"…"}
{"at":"…","kind":"card.answered","habit":"delete-merged-clean","option":"approve"}
{"at":"…","kind":"card.expired","habit":"delete-merged-clean"}
```

- `by` is `first_mate` when the change came through First Mate's gated call
  (the audit already knows), `agent` when a pane's hook shows the agent running
  `git worktree remove/add`, otherwise `user`.
- `facts` on a removal is the core's **last measurement before the worktree
  vanished**. The core measures every live worktree periodically anyway (the
  sweep below needs it), so no app change is needed to know what was in a
  worktree the user deleted from the app.
- The file is the evidence a habit cites. It is trimmed by age (say 90 days),
  not by size.

### Habits

Per project, local to this machine (learned from this user, so not
committed): `~/.config/seahelm/first-mate/habits/<repo-key>.yml`, plus
`habits/_global.yml` for those about every project. Readable and editable by
the user; First Mate shows and changes them only through the core.

```yaml
- id: delete-merged-clean
  about: worktree.cleanup
  when: { pr: merged, days_since_merge: ">=1", uncommitted: 0, untracked: 0,
          ignored_files: 0, unpushed: 0, busy_panes: 0 }
  do: delete_worktree
  level: ask            # observe | suggest | ask | auto
  status: active        # active | superseded (kept in place, beside its replacement)
  observed: 2026-11-05
  sources: [obs-0012, obs-0031, obs-0040]
  origin: inventory     # general | inventory | learned | user
  evidence: { approved: 5, rejected: 0, manual: 3, ignored: 0, since: 2026-11-05 }
  examples: [feat/island-pill, fix/web-question-details]
```

Two kinds:

- **Measurable** habits: `when` uses only the core's vocabulary (below). The
  core matches them itself and they can climb to `auto`.
- **Judgement** habits: `when` is prose ("PRs that only touch docs", "the
  marketing site"). First Mate decides whether one applies; the core caps them
  at `ask`.

Levels, and what each means:

| Level | First Mate… |
|-------|-------------|
| `observe` | does nothing; the habit is a hypothesis being counted. |
| `suggest` | mentions it in the daily brief ("this one looks done"). No card. |
| `ask` | does it after one tap (a card, batched where it can be). |
| `auto` | does it and reports afterwards in the brief. |

### Promotion and demotion (D1)

```
observe ──(N matching user actions)──▶ suggest ──(user says yes)──▶ ask ──(M approvals in a row, user says yes)──▶ auto
   ▲                                                                                                    │
   └─────────────── rejected, undone, or ignored repeatedly → one level down, no question ◀──────────────┘
```

- **Up** happens only through a card the user answers (`habit.promote`,
  showing the evidence: "you approved this 5 times, never rejected; examples
  …"). The core refuses any other path to a higher level — First Mate cannot
  write one, and nor can a conversation.
- **Down** is automatic: a rejection, the user undoing an automatic action
  (recreating a worktree First Mate deleted, restoring its branch), or a card
  of that habit expiring unanswered twice.
- A promotion card is offered at most once per habit per level; declined means
  it waits for fresh evidence (say another N) before asking again.
- Thresholds start at N = 3, M = 5 and tune themselves (D9, below).

### Who may answer a card (D14)

D1 rests on "the user said yes", and a yes is an answer to a card. Until
this check, `cards.answer` and `cards.dismiss` took a call from anyone on
`core.sock`; the only guard was `_meta.caller`, which the caller writes
itself. An agent in any pane — or First Mate, talking to the socket without
its CLI shim — could answer an approval or a `habit.promote` card, and
First Mate has a shell that can rewrite `habits/.granted.json`.

**Threat model.** Everything here runs as one uid, and there is no sandbox
yet: a process set on getting round this always can (copy a client's
executable name, detach from its session and scrub its environment, write
both the grants and their seal). The goal is smaller and holds: no agent and
no First Mate answers a card or raises a level *by accident or by a
straightforward call*, and anything the core refuses or undoes is written
where the user sees it.

**Peer check** (`seahelmd/crates/core/src/peer.rs`). For `cards.answer`,
`cards.dismiss`, `cards.clear`, `cards.raise` and `autopilot.answer` — and for `autopilot.say`
and `command.run`, which speak to First Mate in the user's voice (that sets
`user_spoke` and lets First Mate act at the user's default levels; prose in
`command.run` reaches First Mate when the conversation is bound to it) — the core
takes the connection's peer pid from the kernel (`LOCAL_PEERPID` on macOS,
`SO_PEERCRED` on Linux, `GetNamedPipeClientProcessId` on Windows), reads that
process's ancestry and its exec-time environment (`KERN_PROCARGS2`,
`/proc/<pid>/environ`), and decides:

- a **client** — the macOS app (`….app/Contents/MacOS/Seahelm`), the GPUI
  client (`seahelm-gpui`), seahelm-gateway (web, Telegram) — answers, wherever
  it was launched from. The app relaunched from a pane by `run.sh`, and the
  gateway it starts, carry the pane's variables; they still answer, and the
  core writes an audit line saying so (once per process), so a binary merely
  named like a client shows up there. Recognising clients by path is the
  weak point; once there is a signed release, it becomes a code-signature
  check.
- a process **inside a pane** — `SEAHELM_PANE_ID` or `SEAHELMD_SESSION` in its
  environment, or a `seahelmd __serve` session process among its ancestors —
  is refused: an RPC error (`-32003`) naming why, an audit line, and a note in
  First Mate's timeline.
- a process **outside every pane** (the user's own terminal) answers.
- a caller the core **cannot read** is refused.

In-process calls (First Mate's own approvals running) are the core's and
are not checked. A card raised over the socket may not carry a payload the
core mints (`habit.…`, `autopilot-…`, `proposal-…`) or one an existing card
carries, so a look-alike card cannot carry the user's yes to First Mate. The
app's own control socket no longer answers cards at all (`autopilot.answer`,
`question.answer` and `decision.dismiss` are gone from it): an agent could
reach it, and the app would have passed the answer on as itself. The
`seahelm` CLI only lists cards.

**Grants seal** (`habits.rs`). The core keeps the text it last wrote to
`.granted.json`, in memory and in `.granted.seal.json` with its SHA-256.
Every read compares; a file the core did not write (or a deleted one) is put
back to the core's version and the user gets a note saying so. A seal that
does not match its own digest is not believed: every grant starts over from
`observe` (lowering needs no one's yes), and one note tells the user so. Grants found before the seal
existed are adopted once. `.history/` is not sealed: it only feeds `undo`,
which can only lower a grant.

### Self-tuning (D9)

The thresholds decide when First Mate *asks*, never when it *acts*, so moving
them cannot loosen anything without the user's yes (D1 holds). The core adjusts
them from the observation log, within bounds it enforces:

| Knob | Start | Bounds | Moves down when… | Moves up when… |
|------|-------|--------|------------------|----------------|
| N (actions before a habit is suggested) | 3 | 2–10 | suggestions are accepted | suggestions are declined |
| M (approvals before `auto` is offered) | 5 | 3–20 | promotion offers are accepted | they are declined, or a promoted habit is later demoted |
| Card expiry | 3 days | 1–7 days | the user answers cards fast | the user answers late but does answer |
| Daily proactive card cap | 3 | 1–5 | cards expire unanswered | every card is answered |

Each change is an audit line, and the brief mentions it once ("I'll ask less
often about clean-ups: you've said yes to the last six"). First Mate may also
propose edits to its own judgement habits and brief layout through
`habit propose`, the same card path as any other habit.

### Where habits sit against rules

- A repo's own `.seahelm/automations.yml` is written by a person and shared;
  it **caps** every habit in that repo: the strictest `delete_worktree` level
  any of its enabled rules names (`deny` there beats `auto` in a habit and
  silences it; `ask` holds it at `ask`). A file that does not parse stops
  First Mate in the repo, habits included. The built-in rules (D4) are
  seahelm's, not a person's, and do not cap habits.
- The user's global default (`autopilot_autonomy`) works by its value (D11):
  `deny` stops every habit, approved or not. `ask` caps a habit the user
  never approved (the seed, at `ask` anyway), and a habit's level, once the
  user approved it on a card, **replaces** that default for the cases its
  `when` covers. Otherwise a `delete_worktree: ask` default would keep every
  learned `auto` from ever acting.
- The level the core honours is at most the one it granted
  (`habits/.granted.json`). A higher level written into the file by hand
  waits on a confirmation card (D12).
- Today habits act only through the sweep. First Mate's own gated calls
  (`cleanup-merged` asking to delete a worktree) still take the strictest of
  the rule's level and the user's default; letting a matching habit loosen
  that path — the built-in rule's level as a default a habit may replace,
  only a repo's own file capping — is the next step.
- General rules (D4) keep working as today. `cleanup-merged` stays the
  event-driven path; the habits add the sweep and the learned thresholds. A
  learned habit that proves itself across projects and users is a candidate
  to become a general rule in a later release.

### Generalisation (First Mate)

Once a day while the user has been idle for 30 minutes, the core sends First Mate a `learn.review` event:

- observations since the last review, **pre-grouped by the core** by facts
  signature (e.g. "user removed 4 worktrees: merged, clean, 2–6 days after
  merge"), so the model does not count;
- card outcomes per habit;
- First Mate's own conversation since the last review (corrections such as
  "not that project", "leave docs PRs alone");
- per project, the user's recent prompts to agents (D5), capped.

First Mate may answer with `seahelm habit propose --json '<habit>'` (new; a
card, not an action) or `seahelm habit note <repo> <text>` (project memory,
scenario 5). The core validates a proposed `when` against the vocabulary;
anything outside it makes the habit a judgement habit. Pure counting the core
can do alone (three manual removals with the same signature) does not wait for
the model: the core opens an `observe` habit and the review words it.

### Vocabulary of measured facts (worktrees, first cut)

| Fact | How |
|------|-----|
| `pr` | `merged / closed / open / draft / none`, from the core's PR fetch; a repo with no GitHub remote at all counts as `none` for the inventory (a lookup that is only pending or failed stays unknown, and unknown never matches) |
| `days_since_merge` | PR `mergedAt` |
| `uncommitted`, `untracked` | `git status --porcelain` (as today) |
| `ignored_files` | `git status --ignored --porcelain`, minus known regenerable dirs (`node_modules`, `target`, `.build`, `DerivedData`, `dist`, `.venv`, …); the remainder's names go on the card |
| `unpushed` | commits on HEAD that are on no remote ref **and** not under the PR's head oid (`refs/pull/<n>/head`, or the head oid added to the PR fetch) |
| `idle_days` | since the latest of: last commit, last pane status change, last user prompt in the worktree's panes |
| `busy_panes` | as today |
| `identical_to_base` | `git merge-tree` against the base finds no change (the app's `GitDiff.branchChangedFiles` idea, in the core) |
| `at_risk` | derived, true / false: any of `uncommitted`, `untracked`, `ignored_files`, `unpushed` above zero. False only when all four are known to be zero; unknown `unpushed` with nothing else above zero is unknown (never matches). A `when` with `at_risk: true` is never `auto`; `at_risk: false` pins those four to zero for the safety rule (`busy_panes` still has to be pinned on its own) |
| `is_main`, `has_panes` | main checkout / integration checkout never matches; panes present |

## Interruption budget

Interrupting is the expensive thing, so it is rationed:

- **Three channels by cost.** Silent (audit log only), *report* (one line in
  First Mate's conversation, collected into the brief), *ask* (a card). An
  `auto` habit reports; it never raises a card.
- **The daily brief** — one message a day, sent when the user is likely to
  pick it up (D8, below), in First Mate's conversation and/or through
  seahelm-gateway to Telegram: what I did since the
  last brief, one batched card for what is waiting ("these 4 worktrees can
  go"), task suggestions, research results. Proactive things (tasks, research,
  `suggest`-level habits) go here and nowhere else.
- **Cards expire.** A First Mate card not answered within a few days is
  withdrawn and counted as `ignored` in its habit's evidence (two in a row
  demote it).
- **A per-day cap** on proactive cards (default 3); beyond it, items wait for
  the next brief. Cards answering something the user just asked for do not
  count.
- Quiet hours (`first_mate.quiet_hours`) stay.

### When the brief goes out (D8)

No clock time. The core already knows when the user is at the desk
(`client.visible` → `app_active`, per client), when they type to agents (user
prompts in the message timelines), and when they answer on Telegram (card
answers carry their channel). From that it keeps an activity profile per
weekday, and:

- sends the brief **on arrival**: the first time the user becomes active after
  a long gap (default 4 h, tuned), so it is the first thing they see rather
  than something waiting since 9:00;
- picks the channel by where they are: the island if a desktop client is in
  front, Telegram if they have been answering there and no client is;
- if they have not arrived by their usual start time + an hour (learned from
  the profile), sends it to Telegram once, so a day away still gets one;
- never inside quiet hours, and never twice a day. An urgent item (an `ask`
  card the user's own request is waiting on) does not wait for the brief.

Where they open it (and whether they act on it) is evidence for the next day's
choice.

### As built (phase 5)

- **Presence** (`first_mate/presence.rs`, D15): the core records each signal
  into `first-mate/activity.json` — per weekday, 96 quarter-hour buckets,
  each the count of days the user was active then, decayed by 0.8 a week;
  the last moment seen overall and per channel (`desktop`, `telegram`,
  `web`); the last arrival. Recorded whether First Mate is on or not.
  `presence.state` shows it (read-only). The usual start of a weekday is the
  first bucket from 04:00 on at half the busiest bucket's weight; a weekday
  never seen takes the other days' average. `client.activity {client}` is
  the clients' "keys or mouse in my window" ping (macOS: `TabCoordinator`'s
  local `NSEvent` monitor and `ActivityThrottle`; GPUI: the workspace root's
  `capture_key_down` / `capture_any_mouse_down`).
- **When** (`first_mate/budget.rs`): on arrival — the first signal after 4 h
  without one, still active (a signal in the last 20 min), this brief day;
  else, with no signal at all this brief day, at the usual start + 1 h, to
  Telegram (`Due::Fallback`), only if seahelm-gateway says Telegram is
  reachable (`Due::settle`; the answer is cached for 5 minutes). Once a
  brief day, never in quiet hours (`first_mate_quiet_hours` or any repo's;
  the user's quiet hours also hold back the sweep and rule deliveries),
  never while paused. Every number is in `budget::tuning`, for phase 6.
- **What** (`first_mate/brief.rs`, deterministic, no model turn): a title
  (how long the user was away, or that they have not been at the desk), then
  one line each — *Done* (the audit's actions since the last brief: a
  habit's deletions and the deletions the user approved grouped by name),
  *Waiting on you* (First Mate's cards up or held, and how many come up
  later), *Could go* (worktrees the sweep found at `suggest`), *Notes*
  (habit level changes, cards withdrawn unanswered). Nothing to say: no
  brief, and the day counts as dealt with.
- **Language** (`first_mate/lang.rs`): `config.json` `first_mate_language`,
  `"en"` (default) or `"zh"`, picks the language of the brief and of every
  note row the core writes into First Mate's timeline (sweep and inventory
  lines, habit level changes, refused callers, a tampered grants file). The
  audit log stays English; cards and First Mate's own words, and its action
  descriptions quoted in the brief's *Done*, are not translated yet.
- **Where** (D16): a `brief` row in First Mate's timeline (the island draws a
  block, the web a boxed paragraph); for Telegram the core also publishes
  `first_mate.brief {text, channel}` and seahelm-gateway sends it to the
  default chat. The gateway no longer forwards audit lines with
  `rule: habit:<id>`.
- **Cards** (D17, D18): every card First Mate raises goes through
  `put_card`; held cards are counted in `autopilot.state` as `held` and are
  not in `pending`. Expiry is in memory, like the cards themselves: a core
  restart drops both.

## Prior art: Hermes Agent, OpenClaw, Meta Muse

Researched 2026-11-05 from Hermes's and OpenClaw's own repos
(`NousResearch/hermes-agent` `website/docs/user-guide/features/{memory,skills,curator}.md`;
`openclaw/openclaw` `docs/concepts/{memory,dreaming,user-model,memory-provenance,standing-intents}.md`,
`docs/gateway/heartbeat.md`). Muse is closed; what is known comes from press
coverage of its launch (2026-09) and of a WIRED story (2026-10-03).

| | Hermes | OpenClaw | Muse |
|---|---|---|---|
| Always in context | `MEMORY.md` (2,200 chars) + `USER.md` (1,375), hard caps, a fullness gauge, frozen per session | `USER.md` (4,000 chars of directives) + `MEMORY.md`, truncated past a budget | an editable memory file in a per-user cloud VM |
| Searched on demand | every transcript in SQLite FTS5 (`session_search`) | daily notes `memory/YYYY-MM-DD.md`, hybrid embedding + keyword search | — |
| Writing | the agent's `memory` tool (add / patch / remove; whole-entry replace removed); a background review every ~10 turns, cheaper model, budget | the agent while working; a silent flush before compaction; nightly "dreaming" that promotes only past score gates (frequency, distinct queries, multi-day recurrence) and returns merge/supersede *decisions* with source line refs | hourly pages on every person in the user's life, unstated goals inferred |
| Procedures | `SKILL.md` written after hard-won work; a curator (idle-only, weekly) archives unused ones, never deletes; backups, audit, rollback | Skill Workshop, `propose` mode for drafts, one-word undo | saved workflows as skills (unconfirmed) |
| Control | optional write approval queue, tied to the exact entry text; a "journey" timeline; injection scanning | supersede in place (`observed: DATE \| status: superseded`); forget by session lineage; memory edited off the tracked path or during a web-tainted turn is dropped from context | edit, "best effort" forget; no off switch |
| Personal data | via skills only | Gmail to a separate sandboxed reader agent, as untrusted data | Gmail, Calendar, more; the backlash: profiles of people who never opted in |

What we take, and where it lands in this design:

1. **Small, capped, always-in-context memory; the rest searched.** A project's
   memory injected at SessionStart and into First Mate's context is capped
   (start at 2,000 chars) with a fullness gauge, so First Mate has to prune;
   the observation log is the searchable tier (`seahelm learn search`).
2. **Directives with an observed date, a status and their sources.** Habits
   and memory notes carry `observed`, `status: active|superseded` and `sources`
   (observation ids). A changed preference is superseded in place, never
   appended beside the old one.
3. **Gates before a habit is proposed**: N matching actions **on at least two
   days and in at least two distinct worktrees**. One inventory answer covering
   twelve worktrees is one decision, not twelve.
4. **Review only when idle**, with a token budget, on a cheaper model if set,
   and the first review a full day after First Mate is turned on.
5. **Everything undoable.** Every change to a habit or memory file keeps the
   previous version; "撤销" / `seahelm habit undo` reverts the last; forgetting
   follows lineage (a forgotten observation takes the habits it alone supports
   back down).
6. **Provenance.** Learning reads only what the *user* did and said: their
   actions, card answers, their prompts to agents and to First Mate. Agent
   output, issue bodies, web pages and mail are data, never sources of a
   directive. A memory file edited outside the core is shown to the user and
   kept out of automatic context until confirmed.
7. **The core confirms every write.** Hermes's worst failure is the model
   saying "I'll remember" and never calling the tool. First Mate writes only
   through the core, and the *core* posts the line "记下了：…" in the
   conversation; no line means nothing was saved.
8. **First Mate's long session.** Its context is refreshed at each review, and
   it flushes learnings before its session compacts.

What we refuse, from Muse: no pages about people; nothing inferred about third
parties; forgetting is real deletion along lineage, not best effort; one
switch turns learning off.

## Personal sources (future: mail, calendar)

The user may later authorise mail and calendar. They fit as:

- **Calendar** sharpens the activity profile (D8): no cards during meetings,
  the brief in a gap between them.
- **Mail** is another task source beside GitHub and Jira: candidate tasks go to
  the brief, never straight to action.

Rules, from OpenClaw's design and Muse's backlash: read-only connectors; mail
read by a separate, sandboxed reader whose output is a summary marked
untrusted; nothing from these sources becomes a habit or a memory directive;
no profiles of people; each source switched on and off on its own; still local
(D7), with the same caveat as D5 that what First Mate reads goes to the model.

## Scenario 1 — worktree clean-up (first slice)

**Gap.** Clean-up fires only on an observed `pr.merged`; anything closed,
abandoned, or merged while First Mate was off stays forever. Facts miss
ignored files and misjudge squash-merged branches as unpushed.

**Design.**

1. *Facts v2* — the vocabulary above, on every delete card. On its own this
   makes today's cards honest.
2. *Sweep* — once a day (and when First Mate is turned on), the core measures
   every live worktree and matches the worktree habits. `auto` matches are
   deleted and reported; `ask` matches go on the brief's one batched card;
   `suggest` matches are listed; the rest is untouched.
3. *Inventory (cold start, D6)* — the first time First Mate is turned on, one
   card lists the existing worktrees **grouped by facts signature** ("merged ·
   clean · 12", "PR closed unmerged · 3", "idle 30+ days, nothing unpushed ·
   5", "has unpushed work · 4"), each group with *delete / keep / ask me each
   time* (the at-risk group: *keep / ask me each time* only; its one habit is
   `at_risk: true`). A delete on the merged group goes to the general
   `delete-merged-clean` rather than a second habit saying the same. Each
   answer is one `decision` in the habit's evidence; a delete is also one
   approval. The answers seed habits at `ask` (delete), `observe` (ask each time)
   or a "keep" habit that stops the group being offered, and give the loop its
   first evidence without waiting for the user to delete things they were not
   deleting anyway.
4. *Learning* — every later removal (by anyone) and every card answer is an
   observation; the loop does the rest.

**Safety.** Deletion keeps the branch (as today). Nothing with
`uncommitted`, `untracked`, `ignored_files` or `unpushed` above zero can match
an `auto` habit — the core rejects such a `when` for `auto`, whatever the
evidence. Main and integration checkouts never match.

## Scenario 5 — project memory

**Gap.** One global standing-orders file; nothing per project; agents never
see it.

**Design.** Per project, beside the habits: `memory/<repo-key>.md` — goal,
current milestone, priorities, don'ts, definition of done, plus learned notes
("run the tests before committing", "PR summaries in Chinese"). Sources: the
user's "remember …" to First Mate, and `learn.review` reading the user's
repeated prompts to agents (D5). First Mate reads it before acting on that
project. New-agent briefs point to it; SessionStart supplies its trusted content.

Everything stays local (D7), yet every agent should see it, not only those
First Mate starts. The core already answers every agent's SessionStart hook in
a seahelm pane with added context (`core-hooks/src/suggest.rs`, the suggestion
guidance); it appends the project's memory there too, so Claude Code, Codex and
Cursor agents all start with it without anything being committed. Size-capped,
and only the notes the user has not turned off.

The one-line description of each project (the first line of its memory, or
the repo README's first paragraph until there is one) is what scenario 2 uses
to route.

## Scenario 2 — a requirement becomes a worktree

**Gap.** First Mate must pass `--repo` but is given no list of projects; and
the user's own request still raises a `start_agent` card.

**Design.**

- First Mate gets the project list with one-line descriptions and learned
  **aliases** (`官网` → `seahelm-website`).
- *User mandate*: when the user's message to First Mate names the project (its
  name or an alias — a check the core makes on the user's text, not the model's
  claim), the one `worktree.create` First Mate makes in that turn runs without a
  card and is reported. Otherwise First Mate proposes a card with two or three
  candidate projects; the pick is an observation, and a repeated pick for the
  same words becomes a proposed alias (a habit, promoted like any other).
- Habits and budgets still apply (`max_concurrent_agents`,
  `pause_above_usage`).

### Worked example: the user sends an issue link (D10)

The user sends First Mate `https://github.com/BetaYao/seahelm/issues/123`.

1. **Project.** The core maps `BetaYao/seahelm` to a local repo by its git
   remotes. That is a measured match, as good as the user naming the project, so
   the user mandate applies. No match (not cloned, or not tracked by seahelm):
   one card, "clone it to … / add it as a project?".
2. **Already in hand?** The core looks for a worktree, branch or PR naming
   `#123` (branch name, PR body `Closes #123`, a First Mate brief that cited
   it). Found: First Mate says where ("in `fix/123-login-500`, pane #7, idle")
   and offers to go there. Nothing is created.
3. **Worth starting?** First Mate reads the issue (`gh issue view 123`). Closed,
   a question, or a discussion rather than a task: it says so and stops.
4. **Start.** `worktree.create` with a branch named the way this user names
   branches (a learned habit: prefix by label, issue number, short slug), and a
   brief made of the issue, the project's memory, and the user's learned
   conventions ("plan before coding on features", "`Closes #n` in the PR").
   No card. The report is one line: "Started `fix/123-login-500` in seahelm,
   pane #9".
5. **Learning.** What the user does next is the evidence: renaming the branch,
   telling the agent "plan first, don't code yet", moving it to another project.
   Each becomes a candidate habit (branch naming, per-label kickoff style).

A Jira link works the same once its project key is mapped to a repo. The first
time, First Mate asks which repo; the answer is an alias habit, promoted like any
other.

## Scenario 3 — pulling tasks

**Gap.** `triage-issues` exists (GitHub, off by default); there is no Jira.

**Design.** Per-project task sources in the project's settings: GitHub
(assigned to me, labels, milestone) and Jira (JQL), settled by D27. The core polls
and raises `task.new` events, deduplicated against existing worktrees,
branches and PRs. Tasks only ever appear in the brief; tapping one starts it
(a card answer is the user's yes). Which tasks the user starts and which they
pass over feed a judgement habit for ranking, alongside the project's
priorities from scenario 5. Writing back to Jira or GitHub is a later, separately
gated action.

## Scenario 4 — scheduled jobs and research

**Gap.** Schedules exist only per repo, and First Mate does no work itself.

**Design.** Global schedules in `~/.config/seahelm/first-mate/schedules.yml`
(project-less). A research job is run by an agent First Mate starts in a
dedicated research repo, an ordinary seahelm project, so worktrees, panes and
history come for free; each run commits a dated markdown report. First Mate
reads the new report against the previous one and puts "what changed since last
time" in the brief. Each job has a budget (runtime, usage ceiling). Which
reports the user opens or follows up on is evidence for the job's own habit,
including dropping a job nobody reads.

## Phases (one PR each)

1. **Facts v2.** Ignored-but-not-cache files, PR head oid / `refs/pull` for
   unpushed, idle age, `identical_to_base`; on every delete card. No behaviour
   change beyond honest cards.
2. **Observations.** The core records worktree removals and creations (actor and
   last facts), card answers and expiries.
3. **Habits + sweep.** Habit store, measurable matching in the core, the four
   levels, promotion cards and automatic demotion (D1 enforced), the daily
   sweep. Seed: `cleanup-merged`'s condition as a habit at `ask`.
4. **Inventory card.** First-run grouping and the answers that seed habits.
5. **Interruption budget.** Daily brief (conversation + Telegram), report vs
   card, card expiry as evidence, per-day cap.
6. **Generalisation (as built).** `learn.review`, `seahelm habit propose`,
   judgement habits, bounded persisted self-tuning and Chinese card options.
   Proposals introduce new global/project habits at ask; existing ids are refused. `habit note` belongs to phase 7's project memory.
7. **Project memory and routing — As built** (scenarios 5 and 2, D23–D26): memory files, project
   list and aliases, the user mandate, memory in briefs, routing pick observations.
8. **Task sources — As built** (`first_mate/task_sources.rs`, D27–D30):
   per-project GitHub and Jira sources, bounded background polls, internal
   `task.new` events, persisted offer deduplication, brief-only task choices,
   one-tap worktree creation and ranking observations. GitHub reads through
   `gh`; Jira Cloud uses `/rest/api/3/search/jql`, Server/DC `/rest/api/2/search`.
   The authenticated identity is read for assignment ranking. Branch names and
   PR bodies are checked again before starting; a failed read starts nothing.
   No GitHub or Jira writeback is implemented: that is a later gated action.
9. **Global schedules and the research repo. As built:** `research.rs`, D31–D34. `schedule.list` is readable by panes; mutations require the user. `seahelm schedule add <name> --cron '<5 fields>' --brief '<task>' [--max-minutes 30] [--pause-above-usage 80] [--disabled]`, `list`, `remove <name>`, `run-now <name>`. Jobs and budgets live in `first-mate/schedules.yml`; approvals, runs and brief summaries in `research.json`. Agents commit `reports/<job>/<date>.md` on ordinary worktree branches; First Mate receives `research.done` and stores a short summary with `seahelm research summary <job> '<summary>'`. Visible worktree visits and follow-ups count as readership; after three unread reports a proactive stop card is offered once until new completion evidence. Summary delivery is tried at most three times, then the brief includes “no summary”. Repo registration uses only `core-repos.json` plus `worktree.discovered`; the app owns `workspace_paths`. Invalid schedule entries are isolated and named by `schedule.list`, and `research.json` is written only when its contents change.

Phases 1–5 solve the worktree pile-up end to end; phase 6 widens the learning loop.

## Open questions

Q1 (memory location), Q2 (brief timing), Q5 (thresholds) and Q6 (the
`start_agent` mandate) are settled by D7–D10.

Q3 is settled by D27: both Jira variants, credentials in the local 0600 secrets file.
- **Q4. Research.** Settled by D31: `~/seahelm-research`; summaries and paths only.
Q7 (routing without a named project) is settled by D23: the usual habit
promotion card may grant auto.


### As built (phase 7)

`first_mate/memory.rs` keeps Markdown entries in local `memory/<repo-key>.md`,
with observed day, active/superseded status and sources. Named topics supersede
in place. A digest-sealed snapshot retains prior revisions for undo. Injection
includes active entries only, capped at 2,000 Unicode characters; `memory.show`
returns used/capacity and trust state. External edits raise a user confirmation
card tied to the exact digest and stay out of context meanwhile. The CLI exposes
`memory note`, `memory show`, `memory undo`, and `memory confirm` (the latter
requires the digest returned by show). Undo and confirmation are user-only: restoring an older note can remove a user's
restriction. Only note-writing admits the kernel-identified First Mate session. `/memory show @repo` and `/memory undo @repo`
run directly through core-command from the island, web or Telegram. Rejection
restores the remembered revision and clears the pending card; stale confirmations
cannot approve a newer edit. The core writes
the localized confirmation row after saving.

SessionStart hooks append the pane project's memory for Claude Code, Codex and
Cursor; before pane registration, the hook cwd resolves the repository. Agent
creation adds only a pointer to avoid injecting it twice. Project events append
nonempty memory to First Mate's context. First Mate receives the discovered projects, descriptions and
approved aliases when the user speaks. Core routing checks that original message
against project names and GitHub remotes, with one mandate per turn; otherwise
it raises candidate project actions. Picks feed sealed habits and the existing
promotion cards. Only issue tokens in branch names and worktrees on those branches count as
local duplicates; HEAD SHAs, version names and paths never match. Cached open or
merged PRs require a closing reference in the same repository; reports name the
real path/branch or PR number. Action-level dedupe checks the URL's owner/repo
against the target's remotes. Issue interpretation remains First Mate's read-only
investigation. Default issue branches use `fix/<n>-<slug>`; an active
`branch naming` memory entry may supply a template such as `bug/{n}-{slug}`.

Phase 7 review corrections: the running core remembers each revision and its
history independently of the disk seal (the same process-memory boundary as
habit grants). Editing both disk files cannot change that snapshot. Injection
orders current goal, milestone and don'ts before newest notes and never cuts an
entry in half; the gauge reports the full active total, actual injected count
and an over-capacity warning. Topic separators accept `:` and `：`, but URL
colons stay content. Note bodies cannot contain entry/metadata comment markers;
provenance is written by the core. Candidate cards keep the requested repo first,
then rank alias/description matches. Alias suggestions are short names, approved
on their own card; First Mate may also suggest one with an option's `alias` field.
A start reservation is released on failure and spent on successful creation,
including starts approved under a repo's ask rule; another start asks on a card.


Final phase 7 review: memory undo is exclusively the user's, even when requested
by a kernel-identified First Mate process. The island/web/Telegram command and
outside-terminal CLI remain available. PR bodies stay out of public `pr.list`
and status payloads; the internal routing accessor alone includes them. Issue
branch matching derives a literal-escaped issue pattern from the learned
`branch naming` template, as well as recognizing the default issue tokens.
Alias suggestions skip generic verbs, possessives and very short words, prefer
target-project name components or distinctive description nouns, and reject any
word shared by multiple known projects' names/descriptions.


### Task sources: local operations (phase 8)

Sources live in `first-mate/task-sources/<repo-key>.json`; poll timestamps,
seen/offered identities, pending tasks and the bounded ranking preference live
in `first-mate/tasks.json`. The repo-key is the existing habits repo-key.
All four RPCs (`task-source.add/list/remove/test`) are user-only, including
list and test. A pane process and an unreadable peer are refused even if their
JSON claims to be a client. Source JSON rejects unknown fields, so credentials
cannot be smuggled into the public source configuration. Credentials are
accepted on stdin, never a CLI token argument; curl receives auth on stdin too.

Examples (run from the user's terminal outside any seahelm pane):

```sh
seahelm task-source add --repo /path/to/project --json '{"id":"github","kind":"github","github":"owner/repo","assigned_to_me":true,"labels":["high"],"milestone":"v1","minutes":30}'
seahelm task-source list --repo /path/to/project
seahelm task-source test --repo /path/to/project --id github
seahelm task-source remove --repo /path/to/project --id github
# Jira add reads {"email":"…","token":"…"} (Cloud), or {"token":"…"}
# (Server/DC), from stdin. Supply it from a private credential file or prompt.
seahelm task-source add --repo /path/to/project --json '{"id":"jira","kind":"jira-cloud","site":"https://example.atlassian.net","jql":"assignee = currentUser() AND resolution = Unresolved","minutes":30}' < /private/path/to/credential.json
```

`test` reads the source through the same fetcher but creates no event, candidate,
card or worktree. A poll creates candidates only while First Mate is enabled and
not paused. The core reads local/remote branches and `git worktree list`, including
paths and HEAD messages for detached worktrees. Branches require issue tokens
(`fix/12-…`, `12-…`, `issue-12`, or the Jira key), never an arbitrary bare
number such as `release-12`. Only open or merged PRs count, and their bodies
must contain `Closes|Fixes|Resolves #n` or the Jira key. GitHub sources and Jira
sources whose origin is GitHub use these PR reads. Exact boundaries avoid
#123 matching #12. Answered offers, expiry counts and cooldown deadlines are persisted; pending
tasks on unanswered cards recover after stop/restart. A newly assigned item
becomes offerable again. A first expiry holds the task for seven days, and a second expiry drops it permanently. Expiry produces no user pass or ranking penalty. Unselected items and explicit passes produce
`task.passed`; successful creation produces `task.started`. Source removal and
closed/disappeared fetched issues remove pending candidates. A task already
started elsewhere is refused at click time. Issue text is labelled untrusted
inside one delimited data block, including key, title and body, in the kickoff brief; the core action adds a project-memory pointer and SessionStart injects only the
trusted project revision.

Current bounds and follow-ups: each source's filter should select a modest
backlog (50 returned issues); PR deduplication reads at most 100 open and 100 recently updated merged PRs.
Custom Jira priority names currently rank as neutral unless they match
highest/critical/blocker, high, medium, low/lowest. Pagination beyond these
bounds and user-defined priority mappings remain design questions. Real
GitHub/Jira authentication, live polling, app/Telegram rendering and actual
agent startup are not exercised by the isolated tests.


Phase 8 review fixes: atomic writes use unique 0600 temporary files, remove
legacy/abandoned temps, and surface persistence failures. Refused starts keep
the task available and write a note. Source tests distinguish `auth`,
`not_found`, `bad_jql` and `network` without exposing response bodies or secrets.
Fetcher panics return a failed result to the actor and reset the polling flag.
Jira ADF descriptions become plain text; identity lookup failure only removes
the assignment bonus. The CLI validates source kind before reading credentials
from stdin. Regression fixtures use portable absolute paths and fake clients.


Phase 8 final review: a picked task is held in an in-flight set throughout
preflight and startup, excluded before ranking the next brief. A successful
`Ran` completes the offer; a failed `Ran` restores eligibility. An empty
assignment map is seeded from stored task assignments and the first fetch of
previously known items establishes a baseline, rather than a new assignment.
`branch_hint` is ignored by ordinary `worktree.create` callers; only First
Mate's gated calls and its internal approved execution entry point honor it.
