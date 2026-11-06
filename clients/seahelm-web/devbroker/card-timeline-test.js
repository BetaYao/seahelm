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

check(waitingCount([card('c1', 'question'), card('c2', 'approval'), card('c3', 'suggestion')]) === 2,
  'the todo count excludes suggestions');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
