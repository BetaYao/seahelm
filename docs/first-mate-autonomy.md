# First Mate autonomy: learning to take over the chores

Status: design, under discussion (2026-11-05). Nothing here is built yet.
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

Once a day (with the brief), the core sends First Mate a `learn.review` event:

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
| `pr` | `merged / closed / open / draft / none`, from the core's PR fetch |
| `days_since_merge` | PR `mergedAt` |
| `uncommitted`, `untracked` | `git status --porcelain` (as today) |
| `ignored_files` | `git status --ignored --porcelain`, minus known regenerable dirs (`node_modules`, `target`, `.build`, `DerivedData`, `dist`, `.venv`, …); the remainder's names go on the card |
| `unpushed` | commits on HEAD that are on no remote ref **and** not under the PR's head oid (`refs/pull/<n>/head`, or the head oid added to the PR fetch) |
| `idle_days` | since the latest of: last commit, last pane status change, last user prompt in the worktree's panes |
| `busy_panes` | as today |
| `identical_to_base` | `git merge-tree` against the base finds no change (the app's `GitDiff.branchChangedFiles` idea, in the core) |
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
   time*. The answers seed habits at `ask` (delete), `observe` (ask each time)
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
project, and it goes into the brief of every agent First Mate starts there.

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
(assigned to me, labels) first, Jira later (open question Q3). The core polls
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
6. **Generalisation.** `learn.review`, `seahelm habit propose / note`,
   judgement habits.
7. **Project memory and routing** (scenarios 5 and 2): memory files, project
   list and aliases, the user mandate, memory in briefs, learning from pane
   prompts.
8. **Task sources**: GitHub, then Jira.
9. **Global schedules and the research repo.**

Phases 1–5 solve the worktree pile-up end to end; 6 onward widen the loop.

## Open questions

Q1 (memory location), Q2 (brief timing), Q5 (thresholds) and Q6 (the
`start_agent` mandate) are settled by D7–D10.

- **Q3. Jira.** Cloud (email + API token) or Server/DC (PAT)? Where the
  credential is kept (Keychain vs the gateway, which already holds secrets).
- **Q4. Research.** Where the research repo lives, and whether reports also go
  out in full or only as the brief's summary.
- **Q7. A plain-language request with no link** ("fix the login 500"): the
  mandate needs the project named or an alias. Should First Mate's own routing,
  once it has been right M times in a row for that kind of request, be
  promotable to `auto` like any habit?
