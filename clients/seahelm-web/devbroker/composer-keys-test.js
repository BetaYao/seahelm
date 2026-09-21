// composer-keys-test.js — the timeline composer must not steal an IME's Enter.
//
// Run:  node devbroker/composer-keys-test.js
//
// Typing Chinese goes through a candidate list: Enter picks the word, it does not
// end the sentence. Submitting on that Enter sent the raw pinyin to the agent
// and swallowed the choice, so the composer was unusable in any IME.
'use strict';

const { isComposing, composerKeyAction } = require('../composer-keys.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};

console.log('composer keys');

check(composerKeyAction({ key: 'Enter' }) === 'send', 'plain Enter sends');
check(composerKeyAction({ key: 'Escape' }) === 'esc', 'Escape reaches the pane');
check(composerKeyAction({ key: 'Enter', shiftKey: true }) === null, 'Shift+Enter is the field’s');
check(composerKeyAction({ key: 'a' }) === null, 'ordinary typing is the field’s');

// The bug.
check(composerKeyAction({ key: 'Enter', isComposing: true }) === null,
      'Enter commits an IME candidate, it does not send');
check(composerKeyAction({ key: 'Enter', keyCode: 229 }) === null,
      'keyCode 229 counts as composing where isComposing lags');
check(composerKeyAction({ key: 'Escape', isComposing: true }) === null,
      'Escape cancels the candidate, it does not interrupt the agent');
check(composerKeyAction({ key: 'Enter', isComposing: false }) === 'send',
      'the Enter after the candidate is chosen still sends');

check(isComposing(null) === false, 'no event is not composing');
check(isComposing({ key: 'Enter' }) === false, 'a bare keydown is not composing');
check(composerKeyAction(null) === null, 'no event decides nothing');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
