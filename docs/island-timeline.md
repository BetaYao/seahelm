# The island: one timeline, cards in it, a filter for what waits on you

Status: agreed with the user 2026-11-06; to build. Replaces the island's two
pages (`IslandPage.suggestions` / `.conversation`, switched with "Suggestions N"
and Esc), which the user found covering each other.

## Decisions

| # | Decision |
|---|----------|
| I1 | The opened island is up to **60 % of the screen's visible height** (never under today's 520 pt), still sized to its content. |
| I2 | **One timeline**: First Mate's conversation, events, briefs, notes **and every card** — First Mate's approvals and proposals, other panes' agent questions and permission prompts, suggestions — in time order, newest at the bottom, scrolling up for older. Each card names its source (`First Mate`, or `#7 · saas-mono`). |
| I3 | A card is drawn **whole with its buttons while it waits**; once **answered** it collapses in place to one line (`✓ 你批准了：删除 3 个 worktree · 10:02`); once **expired or gone** (the agent moved on) to a grey line. The timeline is the record of what was decided. |
| I4 | **No second view.** The reminder right of the First Mate title becomes a **filter toggle** (`待办 3`, highlighted when on). On, the same timeline shows only pending suggestion cards: same order, same composer, no page change; all pending suggestions are shown directly, with no message placeholders or folded suggestion groups. Turning it on or off keeps the card nearest the viewport where it is. Sending a message, Esc (first press), or the count reaching 0 turns it off. |
| I5 | When a new card **opens the island by itself**, it opens unfiltered, scrolled to that card, which is briefly highlighted. Opened by the user: unfiltered, at the bottom. |
| I6 | **Suggestions** (`::seahelm-suggest::`) are drawn lighter, at most the 3 most recent shown, and all previous suggestions for a pane are withdrawn when its next turn begins (a submitted prompt, a suggestion selection, or a transition into running). Core publishes the removal to every client, including Island; other panes are unaffected. `待办 N` counts only pending suggestions, and the filter shows only these suggestions. Pending suggestions keep a highlighted border until resolved; questions and approvals are not todos. |

## Contract: card rows in First Mate's timeline (core)

The core writes a row of a new kind **`card`** into First Mate's timeline
(`seahelm-first-mate`, like `note` and `brief`: no turn) for every card, so the
island, the web and the GPUI client read the same history, and it survives a
restart:

- when a card goes up: `{"kind":"card","card_id":…,"card_kind":"approval|proposal|question|choice|suggestion|report|…","source":{"pane":…,"label":"#7 · saas-mono" | "First Mate"},"text":<first line of the card>,"options":[…],"state":"pending"}`
- when it is decided: a second row with the same `card_id` and `"state":"answered"|"dismissed"|"expired"|"gone"`, plus `"option"` (the label picked, when answered) and `"via"` (island, web, telegram …).

Clients merge rows by `card_id`: the card sits where its first row is, the
latest row gives its state. A pending card's buttons come from the live card
(`cards.list`), never from the row, so an answer always goes through
`cards.answer` against the current card. Clients that do not know the kind
drop the row (as for `note` / `brief`). Text is the card's own (already in
`first_mate_language` for First Mate's cards); labels are the shown labels.

Core `decision` message rows carry their option labels too. A client can fold a
nearby First Mate decision into its card when the options match, while keeping
unrelated pane decisions in the timeline. Older decision rows may omit options.

## Out of scope here

The web client draws card rows in a follow-up; Telegram keeps sending cards
as messages. The GPUI client has no island.
