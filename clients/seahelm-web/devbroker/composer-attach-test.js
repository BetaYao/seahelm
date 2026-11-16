// composer-attach-test.js — pasted and picked files become paths in the message.
//
// Run:  node devbroker/composer-attach-test.js
'use strict';

const { filesOf, uploadName, insertPath, composeMessage, pendingCount, isImage, refusal, toBase64, MAX_BYTES } = require('../composer-attach.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};

console.log('composer attach');

const at = new Date(2026, 10, 16, 9, 5, 7);
check(uploadName({ name: 'image.png', type: 'image/png' }, at) === 'screenshot-20261116-090507.png',
  'a pasted screenshot is named for when it was pasted');
check(uploadName({ name: '', type: 'image/jpeg' }, at) === 'screenshot-20261116-090507.jpg',
  'a nameless image takes its extension from its type');
check(uploadName({ name: 'report.pdf', type: 'application/pdf' }, at) === 'report.pdf',
  'a picked file keeps its name');

const shot = { name: 'image.png' };
check(filesOf({ files: [shot] })[0] === shot, 'files come from DataTransfer.files');
check(filesOf({ files: [], items: [{ kind: 'string' }, { kind: 'file', getAsFile: () => shot }] })[0] === shot,
  'or from its file items when files is empty');
check(filesOf({ files: [], items: [{ kind: 'string' }] }).length === 0, 'text alone is no file');
check(filesOf(null).length === 0, 'no DataTransfer, no files');

let r = insertPath('', 0, 0, '/t/a.png');
check(r.value === '/t/a.png ' && r.caret === 9, 'into an empty composer, with a space to type on');
r = insertPath('look at', 7, 7, '/t/a.png');
check(r.value === 'look at /t/a.png ' && r.caret === r.value.length, 'after a word, spaced from it');
r = insertPath('look at  please', 8, 8, '/t/a.png');
check(r.value === 'look at /t/a.png please', 'between spaces, adding none');
r = insertPath('fix this bug', 4, 8, '/t/a.png');
check(r.value === 'fix /t/a.png bug', 'over a selection');
r = insertPath('ab', 1, 1, '/p');
check(r.value === 'a /p b' && r.caret === 5, 'inside a word, spaced both sides');

const atts = [{ path: '/t/a.png' }, { path: null }, { path: null, error: 'x' }, { path: '/t/b.pdf' }];
check(composeMessage(' look at these ', atts) === 'look at these /t/a.png /t/b.pdf',
  'the words, then each uploaded path; pending and failed ones are left out');
check(composeMessage('', atts) === '/t/a.png /t/b.pdf', 'attachments alone are a message');
check(composeMessage('hi', []) === 'hi', 'no attachments, just the words');
check(pendingCount(atts) === 1, 'one still uploading');
check(isImage({ type: 'image/png' }) && !isImage({ type: 'application/pdf' }), 'images are told apart');

check(refusal({ name: 'a', size: 10 }) === '', 'a small file goes');
check(/over 10 MB/.test(refusal({ name: 'big.mov', size: MAX_BYTES + 1 })), 'an oversized one is refused by name');

const buf = new Uint8Array(70000).map((_, i) => i % 251).buffer;
check(toBase64(buf) === Buffer.from(buf).toString('base64'), 'base64 of a buffer larger than one slice');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
