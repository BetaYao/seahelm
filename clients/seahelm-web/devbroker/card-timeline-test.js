// card-timeline-test.js — merge core card rows into First Mate's conversation.
//
// Run: node devbroker/card-timeline-test.js
'use strict';

const { merge, present, waitingCount } = require('../card-timeline.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};
const row = (seq, kind, extra = {}) => ({ seq, ts: seq, kind, ...extra });
const card = (id, kind, extra = {}) => ({ id, kind, created_at: 10 + Number(id.slice(1)), message: id, labels: ['Yes', 'No'], ...extra });

console.log('card timeline fixtures');

{
  const rows = [
    row(1, 'user', { text: 'Please check this' }),
    row(2, 'card', { card_id: 'c1', card_kind: 'approval', source: { pane: 'p1', label: '#7 · saas-mono' }, text: 'Remove the branch?', state: 'pending' }),
    row(3, 'assistant', { text: 'I will wait for your answer.' }),
    row(4, 'card', { card_id: 'c1', state: 'answered', option: 'Approve', via: 'web' }),
  ];
  const items = merge(rows, []);
  const item = items.find(x => x.type === 'card');
  check(items.map(x => x.type).join() === 'message,card,message', 'same card rows occupy the first row position');
  check(item.state === 'answered', 'the latest row wins over an earlier pending row');
  check(item.latest.state === 'answered' && item.option === 'Approve' && item.via === 'web',
    'the latest card row records answer and channel');
  check(item.source.label === '#7 · saas-mono' && item.text === 'Remove the branch?',
    'the first row keeps source and text');
}

{
  const rows = [
    row(20, 'decision', { ts: 100, text: 'Allow this action?', options: ['1. Approve', '2. Reject'] }),
    row(21, 'card', {
      ts: 101, card_id: 'mate-approval', card_kind: 'approval',
      source: { pane: 'seahelm-first-mate', label: 'First Mate' },
      text: 'Allow this action?', options: ['Approve', 'Reject'], state: 'pending',
    }),
  ];
  const live = card('mate-approval', 'approval', {
    pane_session_key: 'seahelm-first-mate', labels: ['Approve', 'Reject'],
  });
  const items = merge(rows, [live]);
  check(items.map(x => x.type).join() === 'card' && items[0].cardId === 'mate-approval',
    'a nearby First Mate decision with matching options folds into its card');

  const mismatched = merge([
    rows[0],
    row(22, 'card', {
      ts: 101, card_id: 'other-pane', card_kind: 'approval',
      source: { pane: 'pane-7', label: '#7 · saas-mono' },
      text: 'Allow this action?', options: ['Approve', 'Reject'], state: 'pending',
    }),
  ], [card('other-pane', 'approval', { pane_session_key: 'pane-7', labels: ['Approve', 'Reject'] })]);
  check(mismatched.some(x => x.type === 'message' && x.message.kind === 'decision'),
    'matching options do not fold a decision from another pane');

  const differentChoices = merge([
    row(25, 'decision', { ts: 100, text: 'Allow this action?', options: ['Approve', 'Always', 'Reject'] }),
    row(26, 'card', {
      ts: 101, card_id: 'mate-different-options', card_kind: 'approval',
      source: { pane: 'seahelm-first-mate', label: 'First Mate' },
      text: 'Allow this action?', options: ['Approve', 'Reject'], state: 'pending',
    }),
  ], [card('mate-different-options', 'approval', { pane_session_key: 'seahelm-first-mate' })]);
  check(differentChoices.some(x => x.type === 'message' && x.message.kind === 'decision'),
    'a nearby First Mate decision with different options remains in the timeline');

  const tooOld = merge([
    row(30, 'decision', { ts: 1, text: 'Allow this action?', options: ['Approve', 'Reject'] }),
    row(31, 'card', {
      ts: 100, card_id: 'later-mate-card', card_kind: 'approval',
      source: { pane: 'seahelm-first-mate', label: 'First Mate' },
      text: 'Allow this action?', options: ['Approve', 'Reject'], state: 'pending',
    }),
  ], [card('later-mate-card', 'approval', { pane_session_key: 'seahelm-first-mate' })]);
  check(tooOld.some(x => x.type === 'message' && x.message.kind === 'decision'),
    'a matching decision outside the near-time window remains in the timeline');
}

{
  const rows = [row(2, 'card', {
    card_id: 'not-yet-loaded', card_kind: 'approval', text: 'Confirm?', state: 'pending',
  })];
  const beforeNotify = merge(rows, [], { cardsReady: false });
  const afterNotify = merge(rows, [], { cardsReady: true });
  check(beforeNotify[0].state === 'pending', 'a pending row stays pending before the first cards notify');
  check(afterNotify[0].state === 'gone', 'a missing card becomes gone after the cards feed is ready');
}

{
  const [item] = merge([row(2, 'card', { card_id: 'c-gone', card_kind: 'question', text: 'Continue?', state: 'pending' })], []);
  check(item.state === 'gone', 'a pending row with no current live card becomes a gone line');
}

{
  const items = merge([
    row(2, 'card', { ts: 20, card_id: 'c-late', card_kind: 'approval', text: 'Approve?', state: 'pending' }),
    row(4, 'card', { ts: 10, card_id: 'c-late', state: 'answered', option: 'Yes' }),
  ], []);
  const item = items.find(x => x.type === 'card');
  check(item.seq === 2 && item.text === 'Approve?' && item.state === 'answered',
    'sequence picks the first and latest rows even when timestamps arrive out of order');
}

{
  const rows = [row(1, 'card', { card_id: 'c2', card_kind: 'question', text: 'Continue?', state: 'pending' })];
  const live = card('c2', 'question', { pane_session_key: 'pane-7', message: 'Continue with deployment?', labels: ['Yes', 'No'] });
  const [item] = merge(rows, [live]);
  check(item.state === 'pending' && item.card === live, 'live feed supplies the waiting card and its buttons');
  check(item.text === 'Continue?' && item.card.message === 'Continue with deployment?', 'row text and live prompt stay distinct');
}

{
  const live = card('c3', 'suggestion', { pane_session_key: 'p3', message: 'Run tests' });
  const [item] = merge([], [live]);
  check(item.state === 'pending' && item.suggestion && item.source.pane === 'p3',
    'a live suggestion without a row remains actionable with its source');
}

{
  const suggestions = Array.from({ length: 5 }, (_, i) => ({
    type: 'card', id: `s${i}`, cardId: `s${i}`, cardKind: 'suggestion', suggestion: true,
    state: 'pending', seq: i + 1, ts: i + 1,
  }));
  const visible = present(suggestions, { suggestionLimit: 3 });
  check(visible.filter(x => x.type === 'card').map(x => x.id).join() === 's2,s3,s4', 'only the three newest suggestions are shown');
  check(visible.find(x => x.type === 'suggestions-more').count === 2, 'older suggestions are behind one More control');
  const expanded = present(suggestions, { suggestionLimit: 3, suggestionsExpanded: true });
  check(expanded.filter(x => x.type === 'card').length === 5 && expanded.at(-1).type === 'suggestions-less',
    'More suggestions expands in place and can be folded again');
}

{
  const suggestions = [
    { type: 'card', id: 'resolved-a', suggestion: true, state: 'answered', seq: 1 },
    { type: 'card', id: 'pending-a', suggestion: true, state: 'pending', seq: 2 },
    { type: 'card', id: 'pending-b', suggestion: true, state: 'pending', seq: 3 },
    { type: 'card', id: 'resolved-b', suggestion: true, state: 'dismissed', seq: 4 },
    { type: 'card', id: 'pending-c', suggestion: true, state: 'pending', seq: 5 },
    { type: 'card', id: 'pending-d', suggestion: true, state: 'pending', seq: 6 },
  ];
  const visible = present(suggestions, { suggestionLimit: 3 });
  check(visible.some(x => x.id === 'resolved-a') && visible.some(x => x.id === 'resolved-b'),
    'resolved suggestions remain as their one-line records');
  check(visible.find(x => x.type === 'suggestions-more').count === 1
    && visible.filter(x => x.type === 'card' && x.state === 'pending').map(x => x.id).join() === 'pending-b,pending-c,pending-d',
  'the suggestion cap applies only to waiting suggestions');
}

{
  const items = [
    { type: 'message', id: 'm1', seq: 1 },
    { type: 'card', id: 'a', seq: 2, state: 'pending', suggestion: false },
    { type: 'message', id: 'm2', seq: 3 },
    { type: 'card', id: 's', seq: 4, state: 'pending', suggestion: true },
    { type: 'message', id: 'm3', seq: 5 },
  ];
  const filtered = present(items, { filtered: true });
  check(filtered.map(x => x.type).join() === 'hidden-run,card,hidden-run,card,hidden-run',
    'the filter keeps waiting cards and suggestions and folds hidden runs');
  check(filtered[0].count === 1 && filtered[0].items[0].id === 'm1', 'a hidden run expands from its original position');
  const expanded = present(items, { filtered: true, expandedRuns: new Set([filtered[0].id]) });
  check(expanded[0].type === 'hidden-less' && expanded[1].id === 'm1', 'an expanded run has an in-place collapse control');

}

{
  const before = present([
    { type: 'message', id: 'first', seq: 10 },
    { type: 'message', id: 'second', seq: 11 },
  ], { filtered: true });
  const after = present([
    { type: 'message', id: 'first', seq: 10 },
    { type: 'message', id: 'second', seq: 11 },
    { type: 'message', id: 'third', seq: 12 },
  ], { filtered: true, expandedRuns: new Set([before[0].id]) });
  check(before[0].id === after[0].id && after[0].type === 'hidden-less'
    && after.slice(1).map(x => x.id).join() === 'first,second,third',
  'an expanded hidden run keeps its first-item id as later messages extend it');
}

check(waitingCount([card('c1', 'question'), card('c2', 'approval'), card('c3', 'suggestion')]) === 2,
  'the todo count excludes suggestions');

{
  const d = (id, seq) => ({ type: 'message', id, seq, message: { kind: 'decision', text: id } });
  const out = present([d('old', 1), { type: 'message', id: 'reply', seq: 2, message: { kind: 'assistant' } }, d('new', 3)]);
  check(out.map(x => x.id).join() === 'reply,new', 'only the latest suggestion line stays');
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
