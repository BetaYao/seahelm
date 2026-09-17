// message-timeline-test.js — the text-mode timeline must not double on reconnect.
//
// Run:  node devbroker/message-timeline-test.js
//
// The gateway replays every pane's ring after authentication, and a live frame
// can arrive before or after that replay. Each case below is one of those
// orderings.
'use strict';

const { appendMessage, oldestSeq } = require('../message-timeline.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};
const msg = (seq) => ({ seq, pane_session_key: 'p', kind: 'tool', tool: 'Read', detail: `f${seq}` });
const seqs = (list) => list.map(m => m.seq).join(',');

console.log('message timeline');

{
  const list = [];
  for (const s of [1, 2, 3]) appendMessage(list, msg(s), 100);
  for (const s of [1, 2, 3]) appendMessage(list, msg(s), 100);
  check(seqs(list) === '1,2,3', 'replaying the same ring adds nothing', seqs(list));
}

{
  const list = [];
  check(appendMessage(list, msg(4), 100) === true, 'a new frame is accepted');
  check(appendMessage(list, msg(4), 100) === false, 'the same seq again is reported as a duplicate');
}

{
  // A live push that raced ahead of the replay it is also part of.
  const list = [];
  appendMessage(list, msg(5), 100);
  for (const s of [3, 4, 5]) appendMessage(list, msg(s), 100);
  check(seqs(list) === '3,4,5', 'replay arriving after a live frame lands in seq order', seqs(list));
}

{
  const list = [];
  for (let s = 1; s <= 5; s++) appendMessage(list, msg(s), 3);
  check(seqs(list) === '3,4,5', 'the cap keeps the newest', seqs(list));
  appendMessage(list, msg(1), 3);
  check(seqs(list) === '3,4,5', 'a frame older than the window does not push out newer ones', seqs(list));
}

console.log('time order');

{
  // Prose written at 11:55:01 reaches the Mac after the tool call it introduces
  // (hook at 11:55:03) was already sent, so it carries the higher seq.
  const list = [];
  appendMessage(list, { seq: 10, ts: 100, kind: 'tool' }, 100);
  appendMessage(list, { seq: 11, ts: 103, kind: 'tool' }, 100);
  appendMessage(list, { seq: 12, ts: 101, kind: 'assistant' }, 100);
  check(list.map(m => m.seq).join(',') === '10,12,11', 'late-flushed prose sits above the call it introduces',
        list.map(m => m.seq).join(','));
  check(oldestSeq(list) === 10, 'the paging cursor is the lowest seq held');
  appendMessage(list, { seq: 9, ts: 102, kind: 'tool' }, 100);
  check(oldestSeq(list) === 9, 'even when that event is not first on screen');
}

{
  const list = [];
  appendMessage(list, { seq: 2, ts: 50 }, 100);
  appendMessage(list, { seq: 1, ts: 50 }, 100);
  check(list.map(m => m.seq).join(',') === '1,2', 'same instant falls back to seq');
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
