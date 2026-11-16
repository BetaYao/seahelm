// slash-complete-test.js — completing an agent's slash commands.
//
// Run:  node devbroker/slash-complete-test.js
'use strict';

const { query, match, apply, kindNote } = require('../slash-complete.js');

let pass = 0, fail = 0;
function check(ok, label) {
  if (ok) { pass++; console.log(`  ok   ${label}`); }
  else { fail++; console.log(`  FAIL ${label}`); }
}

// Only the first word of a message that starts with a slash.
check(query('/comp') === 'comp', 'the word after the slash');
check(query('/') === '', 'a bare slash lists everything');
check(query('/compact keep the plan', 4) === 'compact', 'caret inside the first word');
check(query('/compact keep the plan') === null, 'not once you are typing its arguments');
check(query('fix /etc/hosts') === null, 'not a slash later in the message');
check(query('') === null && query(null) === null, 'nothing typed');

const commands = [
  { name: 'compact', description: 'Compact the conversation', source: 'builtin', kind: 'prompt' },
  { name: 'config', description: 'Open settings', source: 'builtin', kind: 'interactive' },
  { name: 'context', description: 'Show context usage', source: 'builtin', kind: 'info' },
  { name: 'code-review:code-review', description: 'Review a PR', source: 'plugin', kind: 'prompt' },
  { name: 'mattpocock-skills:tdd', description: 'Test-driven development', source: 'plugin', kind: 'prompt' },
  { name: 'commit', description: 'Make a commit', source: 'user', kind: 'prompt' },
  { name: 'model', description: 'Choose the model', source: 'builtin', kind: 'interactive' },
];
const names = (q, n) => match(commands, q, n).map(c => c.name);

check(names('co')[0] === 'compact' || names('co')[0] === 'config', 'prefix matches first, built-ins ahead');
check(names('co').indexOf('commit') > names('co').indexOf('context'), 'a built-in before a file at the same rank');
check(names('tdd')[0] === 'mattpocock-skills:tdd', "a plugin command found by its own part");
check(names('review')[0] === 'code-review:code-review', 'by the name containing it');
check(names('settings')[0] === 'config', 'by its description, from four letters');
check(!names('mod').includes('config') && names('mod')[0] === 'model', 'not by three');
check(names('zq').length === 0, 'nothing fits');
check(names('', 3).length === 3, 'a bare slash, capped');

check(apply('/comp', { name: 'compact' }) === '/compact ', 'completing adds the space for arguments');
check(apply('/comp keep the plan', { name: 'compact' }) === '/compact keep the plan', 'what follows is kept');

check(kindNote('interactive') === 'opens in the terminal', 'a picker says where it opens');
check(kindNote('prompt') === '', 'a prompt is just a turn');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
