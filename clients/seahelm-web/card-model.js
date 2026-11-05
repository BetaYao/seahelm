// Core cards → what the page draws.
//
// The gateway sends the whole current card list (`cards {cards}`) after auth and
// on every change; that list is the truth, so the page rebuilds its decision
// state from it each time rather than patching. Two piles come out:
//
//  - `byPane`: one decision per pane, keyed by pane_session_key, drawn above
//    that pane's composer and on its row and tab. A question or a screen choice
//    reads as a "question"; a suggestion as a "suggest". When a pane holds more
//    than one, a question/choice outranks a suggestion, and otherwise the first
//    in the list wins.
//  - `mate`: First Mate's approvals and proposals, and reports, drawn above
//    First Mate's composer. They may have no pane, so they are keyed by card id.
//
// Answers are by index into `labels` (`cards.answer {id, index}`). For a
// multi-select question the labels are the options with ☑/☐ ticks, then
// "✔ Done": tapping an option toggles it, and Done is index options.length.
//
// Nothing here knows about the DOM.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmCardModel = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // The same words the desktop treats as dangerous.
  const DANGER = /(delete|remove|rm -rf|drop|force|reset --hard|overwrite|revoke)/i;
  const DANGER_KINDS = new Set(['question', 'choice', 'approval']);
  const PANE_KINDS = { question: 'question', choice: 'question', suggestion: 'suggest' };
  const MATE_KINDS = new Set(['approval', 'proposal', 'report']);

  function isDanger(card) {
    return !!card && DANGER_KINDS.has(card.kind) && DANGER.test(String(card.message || ''));
  }

  const TICK = /^\s*[☑☐✓✔]\s*/;

  /** The option texts to show, without the ticks the labels carry. */
  function optionTexts(card) {
    if (Array.isArray(card.options) && card.options.length) return card.options.map(String);
    const labels = Array.isArray(card.labels) ? card.labels.map(String) : [];
    // A multi-select's labels end in Done; that is drawn on its own.
    if (card.multi_select && labels.length) labels.pop();
    return labels.map(l => card.multi_select ? l.replace(TICK, '') : l);
  }

  /** The line under each option, as Claude's dialog shows it: one per
   *  option, '' where an option has none; empty when the card has none or
   *  they do not line up with what is drawn. */
  function optionDetails(card, options) {
    const details = Array.isArray(card.details) ? card.details.map(d => String(d || '').trim()) : [];
    if (details.length !== options.length || !details.some(Boolean)) return [];
    return details;
  }

  /** One card as the pane's reply bar draws it. */
  function toDecision(card) {
    const type = PANE_KINDS[card.kind];
    const multi = type === 'question' && !!card.multi_select;
    // Single-select: show what is tapped, the labels. Multi-select: the
    // options untouched (the ticks are drawn as state) and Done at the end.
    const options = multi ? optionTexts(card)
      : (Array.isArray(card.labels) && card.labels.length ? card.labels.map(String) : optionTexts(card));
    return {
      id: card.id,
      kind: card.kind,
      type,
      prompt: String(card.message || ''),
      // The question's tab title in Claude's dialog ("Customer").
      header: type === 'question' ? String(card.header || '').trim() : '',
      options,
      details: type === 'question' ? optionDetails(card, options) : [],
      multi_select: multi,
      checked: Array.isArray(card.checked) ? card.checked.slice() : [],
      danger: isDanger(card),
      card,
    };
  }

  /** `{byPane: Map<key, decision>, mate: [card]}` from the full card list. */
  function buildDecisions(cards) {
    const byPane = new Map();
    const mate = [];
    for (const card of cards || []) {
      if (!card || card.id == null) continue;
      if (MATE_KINDS.has(card.kind)) {
        mate.push(Object.assign({}, card, { danger: isDanger(card) }));
        continue;
      }
      if (!PANE_KINDS[card.kind]) continue;
      const key = card.pane_session_key || card.pane_id;
      if (!key) continue;
      const have = byPane.get(key);
      const d = toDecision(card);
      if (!have || (have.type === 'suggest' && d.type === 'question')) byPane.set(key, d);
    }
    return { byPane, mate };
  }

  /** What a First Mate card offers to tap: its labels, else its options. */
  function mateLabels(card) {
    if (Array.isArray(card.labels) && card.labels.length) return card.labels.map(String);
    return Array.isArray(card.options) ? card.options.map(String) : [];
  }

  /** The ticks after tapping option i, for the optimistic repaint. */
  function toggleChecked(checked, i) {
    const next = new Set(checked || []);
    if (next.has(i)) next.delete(i); else next.add(i);
    return [...next].sort((a, b) => a - b);
  }

  return { buildDecisions, toDecision, isDanger, mateLabels, toggleChecked, optionTexts };
});
