// pane-pick-test.js — which pane a worktree opens on.
//
// Run:  node devbroker/pane-pick-test.js
'use strict';

const { pickPane, statusLabel, decisionLabel } = require('../pane-pick.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};
const panes = (...statuses) => statuses.map((status, i) => [`p${i}`, { status }]);

console.log('pane pick');

check(pickPane(panes('running', 'waiting', 'idle'), null) === 'p1',
  'a pane waiting on you wins over a running one');
check(pickPane(panes('running', 'failed'), null) === 'p1', 'a failed pane wins over a running one');
check(pickPane(panes('failed', 'waiting'), null) === 'p1', 'waiting outranks failed');
check(pickPane(panes('idle', 'running'), null) === 'p1', 'running wins over idle');
check(pickPane(panes('waiting', 'waiting'), null) === 'p0', 'ties go to the first in display order');

check(pickPane(panes('idle', 'idle', 'done'), 'p2') === 'p2', 'with nothing live, the last pane looked at');
check(pickPane(panes('idle', 'running'), 'p0') === 'p1', 'but a live pane outranks that memory');
check(pickPane(panes('idle', 'idle'), 'gone') === 'p0', 'a remembered pane that closed is ignored');
check(pickPane(panes('idle', 'unknown'), null) === 'p0', 'otherwise the first pane');

// A suggestion arrives as the agent finishes, so its pane reads idle.
const withDecision = panes('running', 'idle', 'waiting');
withDecision[1][1].decision = true;
check(pickPane(withDecision, null) === 'p1', 'an open decision outranks running and waiting alike');
check(pickPane(withDecision, 'p0') === 'p1', 'and the memory of the last pane');

check(pickPane([], 'p0') === null, 'no panes, no pick');
check(pickPane(null, null) === null, 'and no list is the same');

check(statusLabel('waiting') === 'Needs you', 'waiting reads as needing you');
check(statusLabel('failed') === 'Error', 'failed reads as an error');
check(statusLabel('unknown') === '', 'unknown says nothing rather than guess');
check(statusLabel('bogus') === '', 'and so does a status it has never heard of');
check(decisionLabel('suggest') === 'Suggestion', 'a suggestion is labelled as one');
check(decisionLabel('question') === 'Needs you', 'an open question needs you');
check(decisionLabel(undefined) === null, 'no decision, no label');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
