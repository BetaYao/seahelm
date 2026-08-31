// reconnect-test.js — the gateway socket's reconnect policy, on virtual time.
//
// Run:  node devbroker/reconnect-test.js
//
// The MQTT client this replaced reconnected on its own; the gateway socket did
// not, so a phone locking its screen left a dead page. These check the schedule
// and — more important — the two cases where retrying is the wrong answer.
'use strict';

const { createReconnector, DEFAULTS } = require('../reconnect.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};

function makeVirtualTime() {
  let now = 1000, seq = 0;
  const timers = new Map();
  return {
    now: () => now,
    setTimer(fn, ms) { const id = ++seq; timers.set(id, { at: now + ms, fn }); return id; },
    clearTimer(id) { timers.delete(id); },
    advance(ms) {
      const target = now + ms;
      for (;;) {
        let next = null;
        for (const [id, t] of timers) if (!next || t.at < next[1].at) next = [id, t];
        if (!next || next[1].at > target) break;
        now = next[1].at; timers.delete(next[0]); next[1].fn();
      }
      now = target;
    },
  };
}

function harness(over = {}) {
  const vt = makeVirtualTime();
  const attempts = [];
  const schedules = [];
  const r = createReconnector(Object.assign({
    attempt: () => attempts.push(vt.now()),
    onSchedule: (s) => schedules.push(s),
    now: vt.now, setTimer: vt.setTimer, clearTimer: vt.clearTimer,
    random: () => 0.5,              // jitter centred, so delays are exact
  }, over));
  return { vt, attempts, schedules, r };
}

console.log('gateway reconnect');

{
  const { vt, attempts, r } = harness();
  r.closed();
  check(attempts.length === 0, 'does not reconnect synchronously');
  vt.advance(DEFAULTS.baseMs);
  check(attempts.length === 1, 'reconnects after the first delay');
}

// Backoff, or a Mac that is simply off gets hammered.
{
  const { vt, attempts, r } = harness();
  const seen = [];
  for (let i = 0; i < 6; i++) {
    const before = vt.now();
    r.closed();
    vt.advance(DEFAULTS.maxMs + 1);
    seen.push(attempts[attempts.length - 1] - before);
  }
  const rising = seen.every((d, i) => i === 0 || d >= seen[i - 1]);
  check(rising, 'delay grows', `(${seen.join(', ')})`);
  check(seen[seen.length - 1] <= DEFAULTS.maxMs, 'and is capped', `(${seen[seen.length - 1]}ms)`);
}

// A drop after a good connection should feel instant, not resume the backoff
// the last outage climbed to.
{
  const { vt, attempts, r } = harness();
  for (let i = 0; i < 5; i++) { r.closed(); vt.advance(DEFAULTS.maxMs + 1); }
  r.succeeded();
  const before = vt.now();
  r.closed();
  vt.advance(DEFAULTS.baseMs);
  check(attempts[attempts.length - 1] - before === DEFAULTS.baseMs,
        'a successful connect resets the backoff');
}

// The two cases where retrying is wrong.
{
  const { vt, attempts, r } = harness();
  r.stop();                       // credential rejected, or user disconnected
  r.closed();
  vt.advance(60000);
  check(attempts.length === 0, 'stopped means stopped');
  check(r.isStopped, 'and says so');
}
{
  const { vt, attempts, r } = harness();
  r.closed();                     // one in flight
  r.stop();                       // user hits 断开 while it is pending
  vt.advance(60000);
  check(attempts.length === 0, 'stop cancels a pending retry');
}
{
  const { vt, attempts, r } = harness();
  r.stop();
  r.resume();                     // new code entered, or page came back
  r.closed();
  vt.advance(DEFAULTS.baseMs);
  check(attempts.length === 1, 'resume starts over from the short delay');
}

// One close should not queue several timers.
{
  const { vt, attempts, r } = harness();
  r.closed(); r.closed(); r.closed();
  vt.advance(DEFAULTS.maxMs + 1);
  check(attempts.length === 1, 'repeated closes schedule one attempt', `(${attempts.length})`);
}

// Phones come back together — after a train tunnel, after a WiFi drop. Without
// jitter they would all hit the gateway on the same tick.
{
  const { r } = harness({ random: Math.random });
  const seen = new Set();
  for (let i = 0; i < 40; i++) seen.add(r.delayFor(3));
  check(seen.size > 1, 'delays are jittered', `(${seen.size} distinct of 40)`);
}

console.log('\nschedule (jitter centred)');
{
  const { r } = harness();
  const row = [0, 1, 2, 3, 4, 5, 6].map((n) => `${r.delayFor(n)}ms`);
  console.log('  ' + row.join('  →  '));
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
