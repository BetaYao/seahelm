// First Mate's conversation plus the card rows written into its MessageStream.
// Card rows keep their first position and fold later rows with the same id into
// that item; live cards supply buttons, never the historical state.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmCardTimeline = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  function number(value, fallback) {
    const n = Number(value);
    return Number.isFinite(n) ? n : fallback;
  }

  function timeOf(value) {
    const raw = value && (value.ts ?? value.created_at ?? value.timestamp);
    if (typeof raw === 'string' && !/^\d+(\.\d+)?$/.test(raw)) {
      const parsed = Date.parse(raw);
      return Number.isFinite(parsed) ? parsed / 1000 : null;
    }
    const n = Number(raw);
    return Number.isFinite(n) ? n : null;
  }

  const FIRST_MATE_PANE = 'seahelm-first-mate';
  const DECISION_CARD_WINDOW_SECONDS = 60;

  function normalizedOptions(value) {
    const options = value && (Array.isArray(value.options) ? value.options
      : Array.isArray(value.labels) ? value.labels : null);
    if (!options || !options.length) return null;
    return options.map(option => String(option)
      .replace(/^\s*\d+\s*[.)]\s*/, '')
      .replace(/^\s*[☑☐✓✔]\s*/, '')
      .replace(/\s+/g, ' ')
      .trim()
      .toLowerCase());
  }

  function isFirstMateCard(item) {
    const source = item.source || {};
    const card = item.card || {};
    return source.pane === FIRST_MATE_PANE
      || card.pane_session_key === FIRST_MATE_PANE
      || card.pane_id === FIRST_MATE_PANE
      || source.label === 'First Mate';
  }

  function sameOptions(a, b) {
    const left = normalizedOptions(a), right = normalizedOptions(b);
    return !!left && !!right && left.length === right.length
      && left.every((option, i) => option === right[i]);
  }

  function nearInTime(a, b) {
    const left = timeOf(a), right = timeOf(b);
    return left != null && right != null
      && Math.abs(left - right) <= DECISION_CARD_WINDOW_SECONDS;
  }

  function timeDistance(a, b) {
    const left = timeOf(a), right = timeOf(b);
    return left == null || right == null ? Infinity : Math.abs(left - right);
  }

  function compare(a, b) {
    const ta = timeOf(a), tb = timeOf(b);
    if (ta != null && tb != null && ta !== tb) return ta - tb;
    const sa = number(a && a.seq, 0), sb = number(b && b.seq, 0);
    if (sa !== sb) return sa - sb;
    return String(a && a.id || '').localeCompare(String(b && b.id || ''));
  }

  function cardId(card) {
    const id = card && (card.card_id ?? card.id);
    return id == null ? '' : String(id);
  }

  function sourceForCard(card) {
    if (!card) return { label: 'First Mate' };
    if (card.source && card.source.label) return card.source;
    const key = card.pane_session_key || card.pane_id;
    if (!key && ['approval', 'proposal', 'report'].includes(card.kind)) return { label: 'First Mate' };
    return { pane: key || '', label: card.source_label || '' };
  }

  /** Merge fixture/core card rows with the current cards feed. */
  function merge(messages, cards, { cardsReady = true } = {}) {
    const live = new Map();
    for (const card of cards || []) {
      const id = cardId(card);
      if (id) live.set(id, card);
    }

    const sorted = (messages || []).slice().sort(compare);
    const output = [];
    const cardRows = new Map();
    let maxSeq = sorted.reduce((n, row) => Math.max(n, number(row && row.seq, 0)), 0);

    for (const row of sorted) {
      if (!row || row.kind !== 'card') {
        output.push({ type: 'message', id: `message:${row && row.seq}`, seq: row && row.seq, ts: row && row.ts, message: row });
        continue;
      }
      const id = cardId(row);
      if (!id) continue;
      const rows = cardRows.get(id) || [];
      rows.push(row);
      cardRows.set(id, rows);
    }

    const merged = new Map();
    for (const [id, rows] of cardRows) {
      const bySeq = rows.slice().sort((a, b) => number(a.seq, Infinity) - number(b.seq, Infinity));
      const first = bySeq[0], latest = bySeq[bySeq.length - 1];
      const item = {
        type: 'card', id: `card:${id}`, cardId: id, seq: first.seq, ts: first.ts,
        first, latest, source: first.source || latest.source || null,
      };
      merged.set(id, item);
      output.push(item);
    }

    for (const item of merged.values()) {
      const latestState = String(item.latest.state || item.first.state || 'pending').toLowerCase();
      const card = live.get(item.cardId) || null;
      item.cardKind = item.first.card_kind || (card && card.kind) || 'card';
      item.suggestion = item.cardKind === 'suggestion';
      item.text = String(item.first.text || (card && card.message) || '');
      item.source = item.source || sourceForCard(card);
      item.state = latestState === 'pending' && !card && cardsReady ? 'gone' : latestState;
      if (item.state === 'pending') item.card = card;
      item.option = item.latest.option || null;
      item.via = item.latest.via || null;
    }

    let fallback = 0;
    for (const card of cards || []) {
      const id = cardId(card);
      if (!id || merged.has(id)) continue;
      const created = card.created_at ?? card.ts;
      const seq = number(card.seq, maxSeq + (++fallback / 1000));
      output.push({
        type: 'card', id: `card:${id}`, cardId: id, cardKind: card.kind || 'card',
        suggestion: card.kind === 'suggestion', text: String(card.message || ''),
        source: sourceForCard(card), state: 'pending', card, option: null, via: null,
        seq, ts: created,
      });
    }

    // First Mate's TUI decisions also appear as `decision` message rows. When
    // their options and timestamp identify the matching First Mate card, keep
    // the actionable card in that position instead of drawing both rows.
    const duplicateDecisions = new Set();
    for (const item of merged.values()) {
      if (!isFirstMateCard(item)) continue;
      const options = normalizedOptions(item.first) ? item.first : item.card;
      if (!normalizedOptions(options)) continue;
      const decision = output.filter(entry => entry.type === 'message'
        && entry.message && entry.message.kind === 'decision'
        && !duplicateDecisions.has(entry.id)
        && sameOptions(options, entry.message)
        && nearInTime(item.first, entry.message))
        .sort((a, b) => timeDistance(item.first, a.message) - timeDistance(item.first, b.message))[0];
      if (decision) duplicateDecisions.add(decision.id);
    }

    return output.filter(item => !duplicateDecisions.has(item.id)).sort(compare);
  }

  function isSuggestion(item) {
    return item && item.type === 'card' && item.suggestion;
  }

  /** Suggestions stay in their original positions; older ones fold at the oldest. */
  function capSuggestions(items, limit, expanded) {
    const max = Math.max(0, Number.isFinite(limit) ? limit : 3);
    const suggestions = items.filter(item => isSuggestion(item) && item.state === 'pending');
    if (suggestions.length <= max) return items.slice();
    const older = suggestions.slice(0, suggestions.length - max);
    const olderIds = new Set(older.map(item => item.id));
    const first = older[0];
    const control = {
      type: expanded ? 'suggestions-less' : 'suggestions-more',
      id: 'suggestions-more', seq: first.seq, ts: first.ts, count: older.length,
      items: older,
    };
    const out = [];
    let placed = false;
    for (const item of items) {
      if (!olderIds.has(item.id)) { out.push(item); continue; }
      if (!placed && !expanded) {
        out.push(control);
        placed = true;
      }
      if (expanded) out.push(item);
    }
    if (expanded) out.push({ ...control, type: 'suggestions-less', seq: older[older.length - 1].seq });
    return out;
  }

  function visibleInFilter(item) {
    if (item.type === 'suggestions-more' || item.type === 'suggestions-less') return true;
    return item.type === 'card' && item.state === 'pending';
  }

  /** Filter to pending cards/suggestions and collapse each hidden run in place. */
  /** Only a pane's latest suggestion line stays: each reply that ended with
   *  suggestions left its `decision` row, and they piled up down the
   *  timeline. An earlier one goes once a later one comes. */
  function latestDecisionOnly(items) {
    const isDecision = item => item.type === 'message' && item.message && item.message.kind === 'decision';
    let last = -1;
    items.forEach((item, i) => { if (isDecision(item)) last = i; });
    return items.filter((item, i) => !isDecision(item) || i === last);
  }

  function present(items, { filtered = false, expandedRuns = new Set(), suggestionsExpanded = false, suggestionLimit = 3 } = {}) {
    const capped = capSuggestions(latestDecisionOnly(items), suggestionLimit, suggestionsExpanded);
    if (!filtered) return capped;
    const out = [];
    let hidden = [];
    const flush = () => {
      if (!hidden.length) return;
      const first = hidden[0], last = hidden[hidden.length - 1];
      const id = `hidden:${first.id}`;
      const group = { type: 'hidden-run', id, seq: first.seq, ts: first.ts, count: hidden.length, items: hidden };
      if (expandedRuns.has(id)) {
        out.push({ ...group, type: 'hidden-less' }, ...hidden);
      } else out.push(group);
      hidden = [];
    };
    for (const item of capped) {
      if (visibleInFilter(item)) { flush(); out.push(item); }
      else hidden.push(item);
    }
    flush();
    return out;
  }

  function waitingCount(cards) {
    return (cards || []).filter(card => card && card.kind !== 'suggestion').length;
  }

  return { merge, present, waitingCount, compare };
});
