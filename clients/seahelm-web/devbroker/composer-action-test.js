// composer-action-test.js — one button, three meanings.
//
// Run:  node devbroker/composer-action-test.js
'use strict';

const { composerAction, modelLabel } = require('../composer-action.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};
const act = (o) => composerAction(Object.assign({ hasText: false, status: 'idle', ready: true }, o));

console.log('composer action');

check(act({}) === 'none', 'an empty composer at a resting pane does nothing');
check(act({ hasText: true }) === 'send', 'typed text sends');

check(act({ status: 'running' }) === 'stop', 'an empty composer at a running pane stops it');
check(act({ status: 'waiting' }) === 'stop', 'and at one waiting on you — Esc is "never mind"');

// The precedence that matters: you type *while* the agent works.
check(act({ hasText: true, status: 'running' }) === 'send',
  'text still sends while the agent is running');
check(act({ hasText: true, status: 'waiting' }) === 'send',
  'text still sends while the agent waits on you');

// Nothing to stop.
check(act({ status: 'failed' }) === 'none', 'a failed pane is not stoppable');
check(act({ status: 'done' }) === 'none', 'nor a finished one');
check(act({ status: 'unknown' }) === 'none', 'nor one we cannot read');

// Not connected, or no pane chosen.
check(act({ ready: false, hasText: true, status: 'running' }) === 'none',
  'nothing is offered while the socket is down');
check(act({ ready: false }) === 'none', 'or with no pane selected');

check(composerAction(null) === 'none', 'no input at all is inert');
check(composerAction({}) === 'none', 'and so is an empty object');

// The model, as the composer's tag names it.
check(modelLabel('claude-opus-5-5') === 'Opus 5.5', 'a Claude id reads as its name');
check(modelLabel('claude-sonnet-4-5-20250929') === 'Sonnet 4.5', 'a snapshot date is dropped');
check(modelLabel('claude-opus-4-1[1m]') === 'Opus 4.1', 'and so is the context tag');
check(modelLabel('claude-fable-5') === 'Fable 5', 'a whole-number version');
check(modelLabel('claude-3-5-haiku-20241022') === 'Haiku 3.5', 'the older order');
check(modelLabel('gpt-6.1-sol', 'xhigh') === 'gpt-6.1-sol · xhigh', 'other ids as written, effort after');
check(modelLabel('', 'high') === '' && modelLabel(null) === '', 'no model, no label');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
