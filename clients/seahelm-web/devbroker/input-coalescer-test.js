// input-coalescer-test.js — the keystroke path, on virtual time.
//
// Run:  node devbroker/input-coalescer-test.js
//
// No broker and no browser: the coalescer takes its clock and its timers as
// arguments precisely so the latency it adds can be measured directly. That
// matters because the Swift benchmark next door, testKeystrokeEchoRoundTripLatency,
// drives HostGatewayServer straight — the browser is not in its loop, so the
// delay this file measures was invisible to it. That is why an unconditional
// 10ms wait on every burst survived a round of latency work.
'use strict';

const { createKeystrokeCoalescer } = require('../input-coalescer.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};

/** A clock and timer queue we drive by hand. */
function makeVirtualTime() {
  let now = 1000;                 // not 0: catches "measured from the epoch" bugs
  let seq = 0;
  const timers = new Map();
  return {
    now: () => now,
    setTimer(fn, ms) { const id = ++seq; timers.set(id, { at: now + ms, fn }); return id; },
    clearTimer(id) { timers.delete(id); },
    /** Advance, firing timers in due order. */
    advance(ms) {
      const target = now + ms;
      for (;;) {
        let next = null;
        for (const [id, t] of timers) if (!next || t.at < next[1].at) next = [id, t];
        if (!next || next[1].at > target) break;
        now = next[1].at;
        timers.delete(next[0]);
        next[1].fn();
      }
      now = target;
    },
  };
}

function harness(windowMs = 10) {
  const vt = makeVirtualTime();
  const sends = [];
  const c = createKeystrokeCoalescer({
    windowMs,
    send: (payload) => sends.push({ at: vt.now(), payload }),
    now: vt.now,
    setTimer: vt.setTimer,
    clearTimer: vt.clearTimer,
  });
  return { vt, sends, c };
}

console.log('keystroke coalescer');

// The whole point: a keystroke into an idle pane must not wait for a window
// that has nothing to coalesce it with.
{
  const { vt, sends, c } = harness();
  const t0 = vt.now();
  c.push('a');
  check(sends.length === 1, 'idle keystroke sends immediately');
  check(sends[0] && sends[0].at - t0 === 0, 'with zero added latency',
        sends[0] ? `(waited ${sends[0].at - t0}ms)` : '(never sent)');
}

// …including the very first of the session, which a lastSent of 0 would have
// made wait out a window measured from the epoch.
{
  const { sends, c } = harness();
  c.push('x');
  check(sends.length === 1, 'the first keystroke of a session is idle too');
}

// A burst is what the window is for.
{
  const { vt, sends, c } = harness();
  c.push('a');                       // leading edge, out at once
  c.push('b'); c.push('c');          // inside the window
  check(sends.length === 1, 'burst does not send per keystroke');
  vt.advance(10);
  check(sends.length === 2, 'burst flushes when the window closes');
  check(sends[1] && sends[1].payload === 'bc', 'coalesced in order',
        sends[1] ? `(got ${JSON.stringify(sends[1].payload)})` : '');
}

// Typing steadily must not degrade into one message per keystroke.
{
  const { vt, sends, c } = harness();
  for (let i = 0; i < 30; i++) { c.push('k'); vt.advance(4); }   // ~250 wpm
  check(sends.length < 30, 'sustained typing still coalesces', `(${sends.length} sends for 30 keys)`);
  check(sends.length > 1, 'and still gets there', `(${sends.length})`);
}

// Going idle re-arms the fast path, or the win lasts one burst.
{
  const { vt, sends, c } = harness();
  c.push('a'); vt.advance(50);
  const before = vt.now();
  c.push('b');
  check(sends.length === 2 && sends[1].at === before, 'idle again → immediate again');
}

{
  const { vt, sends, c } = harness();
  c.push('a'); c.push('b');
  c.cancel();
  vt.advance(50);
  check(sends.length === 1, 'cancel drops buffered input and its timer');
  check(!c.hasPending, 'and reports nothing pending');
}

{
  const { sends, c } = harness();
  c.push('a'); c.push('b');
  c.flushNow();
  check(sends.length === 2 && sends[1].payload === 'b', 'flushNow sends without waiting');
}

// ── the measurement ───────────────────────────────────────────────────────
// What the old policy cost, in the units a person feels.
console.log('\nadded latency on the first keystroke of a burst');
{
  const windowMs = 10;
  const { vt, sends, c } = harness(windowMs);
  const t0 = vt.now();
  c.push('a');
  vt.advance(windowMs);
  const leading = sends[0].at - t0;
  console.log(`  leading-edge (now):  ${leading}ms`);
  console.log(`  trailing-edge (was): ${windowMs}ms`);
  console.log(`  saved per burst:     ${windowMs - leading}ms`);
  check(leading === 0, 'the fix removes the whole window');
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
