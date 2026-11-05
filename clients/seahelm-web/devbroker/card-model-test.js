// card-model-test.js — core cards into the page's decision state.
//
// Run:  node devbroker/card-model-test.js
'use strict';

const { buildDecisions, isDanger, mateLabels, toggleChecked } = require('../card-model.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};
const card = (o) => Object.assign({ id: 'c' + Math.random(), options: [], labels: [] }, o);

console.log('card model');

{
  const { byPane, mate } = buildDecisions([
    card({ id: 'q', kind: 'question', pane_session_key: 'p1', message: 'Proceed?', options: ['Yes', 'No'], labels: ['Yes', 'No'] }),
    card({ id: 's', kind: 'suggestion', pane_session_key: 'p2', message: 'next', options: ['Run tests'], labels: ['Run tests'] }),
  ]);
  check(byPane.get('p1').type === 'question' && byPane.get('p1').id === 'q', 'a question is keyed by its pane as a question');
  check(byPane.get('p2').type === 'suggest', 'a suggestion reads as a suggest');
  check(byPane.get('p1').prompt === 'Proceed?', 'the message is the prompt');
  check(mate.length === 0, 'no First Mate cards');
}

{
  // AskUserQuestion: the tab title and the line under each option.
  const { byPane } = buildDecisions([card({
    id: 'q', kind: 'question', pane_session_key: 'p', message: 'Which customer?', header: 'Customer',
    options: ['Banana (Recommended)', 'None'], labels: ['Banana (Recommended)', 'None'],
    details: ['closing the books', ''],
  })]);
  const d = byPane.get('p');
  check(d.header === 'Customer', 'a question carries its header');
  check(d.details.length === 2 && d.details[0] === 'closing the books' && d.details[1] === '',
    'details line up with the options, empty where an option has none');
}

{
  const { byPane } = buildDecisions([
    card({ id: 'q', kind: 'question', pane_session_key: 'p1', options: ['a', 'b'], labels: ['a', 'b'], details: ['only one'] }),
    card({ id: 'q2', kind: 'question', pane_session_key: 'p2', options: ['a'], labels: ['a'] }),
    card({ id: 's', kind: 'suggestion', pane_session_key: 'p3', labels: ['x'], header: 'H', details: ['d'] }),
  ]);
  check(byPane.get('p1').details.length === 0, 'details that do not line up are dropped');
  check(byPane.get('p2').details.length === 0 && byPane.get('p2').header === '', 'a card without them has none');
  check(byPane.get('p3').header === '' && byPane.get('p3').details.length === 0, 'a suggestion never shows them');
}

{
  const { byPane } = buildDecisions([card({ id: 'c', kind: 'choice', pane_id: 'id9', labels: ['1. a', '2. b'], options: ['a', 'b'] })]);
  check(byPane.get('id9').type === 'question', 'a screen choice reads as a question');
  check(byPane.get('id9').options.join() === '1. a,2. b', 'single-select shows the labels');
}

{
  const { byPane } = buildDecisions([
    card({ id: 's', kind: 'suggestion', pane_session_key: 'p', labels: ['x'] }),
    card({ id: 'q', kind: 'question', pane_session_key: 'p', labels: ['y'] }),
    card({ id: 'q2', kind: 'question', pane_session_key: 'p', labels: ['z'] }),
  ]);
  check(byPane.get('p').id === 'q', 'a question outranks a suggestion on the same pane, first question wins');
}

{
  const { byPane } = buildDecisions([card({
    id: 'm', kind: 'question', pane_session_key: 'p', multi_select: true, checked: [1],
    options: ['A', 'B'], labels: ['☐ A', '☑ B', '✔ Done'],
  })]);
  const d = byPane.get('p');
  check(d.multi_select && d.options.join() === 'A,B', 'multi-select shows the bare options, Done drawn apart');
  check(d.checked.join() === '1', 'ticks come from checked');
}

{
  const { byPane } = buildDecisions([card({
    id: 'm', kind: 'question', pane_session_key: 'p', multi_select: true, options: [],
    labels: ['☐ A', '☑ B', '✔ Done'],
  })]);
  check(byPane.get('p').options.join() === 'A,B', 'without options, labels lose their ticks and Done');
}

{
  const { byPane, mate } = buildDecisions([
    card({ id: 'a', kind: 'approval', message: 'Delete branch x?', labels: ['Approve', 'Reject'] }),
    card({ id: 'p', kind: 'proposal', pane_session_key: 'p1', message: 'Try', options: ['Go'] }),
    card({ id: 'r', kind: 'report', message: 'done' }),
  ]);
  check(mate.map(c => c.id).join() === 'a,p,r', 'approvals, proposals and reports go to First Mate, in order');
  check(byPane.size === 0, 'and never onto a pane');
  check(mate[0].danger === true && mate[1].danger === false, 'an approval to delete is dangerous');
  check(mateLabels(mate[0]).join() === 'Approve,Reject', 'First Mate cards tap their labels');
  check(mateLabels(mate[1]).join() === 'Go', 'falling back to options');
}

check(isDanger({ kind: 'question', message: 'git reset --hard?' }), 'reset --hard is dangerous');
check(isDanger({ kind: 'choice', message: 'Force push' }), 'case-insensitive');
check(!isDanger({ kind: 'suggestion', message: 'delete it' }), 'a suggestion is never dangerous');
check(!isDanger({ kind: 'question', message: 'Run tests?' }), 'an ordinary question is not');

check(buildDecisions(null).byPane.size === 0, 'no cards, nothing');
check(buildDecisions([{ kind: 'question', pane_session_key: 'p' }]).byPane.size === 0, 'a card without an id is skipped');
check(buildDecisions([card({ kind: 'question' })]).byPane.size === 0, 'a pane card with no pane is skipped');

check(toggleChecked([0, 2], 2).join() === '0', 'toggling a tick off');
check(toggleChecked([2], 0).join() === '0,2', 'toggling a tick on, sorted');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
