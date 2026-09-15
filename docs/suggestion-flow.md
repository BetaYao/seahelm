# Suggestion Flow

Seahelm's suggestion path is instruction-primary and non-blocking. An agent may
report options through the installed `seahelm-suggest` command/plugin, or place
an inline marker in its final response:

    ::seahelm-suggest:: first option | second option

The Stop hook is observation-only. It forwards the final response to Seahelm,
where the marker is parsed into a `suggest` event and rendered as a clickable
card. A response without the marker is still a normal completed turn; Seahelm
does not return `decision:block` or inject a follow-up prompt.

## Cursor Agent

Cursor's `afterAgentResponse` event carries the final response text, so Seahelm
parses the same marker there. Cursor's Stop payload has no final response and is
never used to force a follow-up.

## Correlation

The control socket carries the stable `pane_id` on both command/plugin events
and native hook events. This lets Seahelm associate a suggestion with the pane
that produced it without relying on the agent's session-id format.

## Background work

Suggestions emitted while a subagent, shell task, or cron task is still running
are dropped. The main agent has not reached a real end-of-turn yet and will
report again when the background work settles.

## Viewport choices

Permission prompts and `AskUserQuestion` choices are a separate channel. The
status poller reads those from the live viewport and renders a question card;
selecting a card sends the corresponding keys back to the original pane.
