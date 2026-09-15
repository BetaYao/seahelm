// touch-scroll-test.js — one-finger vertical swipe → terminal scroll.
//
// Run:  node devbroker/touch-scroll-test.js
//
// xterm.js (and ghostty-web) listen for wheel, not touch. On a phone the
// WebGL canvas eats the gesture, so this module is the thing that turns a
// swipe into the same delta a mouse wheel would have produced.
'use strict';

const { createTouchScroller } = require('../touch-scroll.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};

function harness(over = {}) {
  const deltas = [];
  const s = createTouchScroller(Object.assign({
    slop: 10,
    scroll: (deltaY) => deltas.push(deltaY),
  }, over));
  return { s, deltas };
}

function swipe(s, from, to, steps) {
  s.start({ x: from.x, y: from.y, touches: 1 });
  const n = steps || 2;
  let consumed = false;
  for (let i = 1; i <= n; i++) {
    const x = from.x + (to.x - from.x) * (i / n);
    const y = from.y + (to.y - from.y) * (i / n);
    const r = s.move({ x, y, touches: 1 });
    if (r && r.consume) consumed = true;
  }
  s.end();
  return consumed;
}

console.log('touch scroll');

{
  const { s, deltas } = harness();
  const consumed = swipe(s, { x: 40, y: 80 }, { x: 42, y: 84 });
  check(deltas.length === 0, 'a tap does not scroll');
  check(!consumed, 'and does not eat the tap');
}

{
  const { s, deltas } = harness();
  swipe(s, { x: 40, y: 40 }, { x: 40, y: 100 });
  const total = deltas.reduce((a, b) => a + b, 0);
  check(total < 0, 'finger down scrolls toward older output', `(${total})`);
}

{
  const { s, deltas } = harness();
  swipe(s, { x: 40, y: 100 }, { x: 40, y: 40 });
  const total = deltas.reduce((a, b) => a + b, 0);
  check(total > 0, 'finger up scrolls toward live output', `(${total})`);
}

{
  const { s, deltas } = harness();
  swipe(s, { x: 40, y: 80 }, { x: 40, y: 140 });
  const total = Math.abs(deltas.reduce((a, b) => a + b, 0));
  check(total === 60, 'the wheel delta matches the swipe in pixels', `(${total})`);
}

{
  const { s, deltas } = harness();
  const consumed = swipe(s, { x: 20, y: 80 }, { x: 120, y: 84 });
  check(deltas.length === 0, 'a horizontal swipe does not scroll');
  check(!consumed, 'and is left for the TUI');
}

{
  const { s, deltas } = harness();
  s.start({ x: 40, y: 40, touches: 1 });
  s.move({ x: 40, y: 80, touches: 1 });           // lock vertical
  s.move({ x: 70, y: 110, touches: 1 });          // then drift sideways
  const total = deltas.reduce((a, b) => a + b, 0);
  check(total === -70, 'a vertical lock keeps scrolling on a diagonal drift', `(${total})`);
}

{
  const { s, deltas } = harness();
  s.start({ x: 20, y: 80, touches: 1 });
  s.move({ x: 80, y: 82, touches: 1 });           // lock horizontal
  const later = s.move({ x: 90, y: 140, touches: 1 });
  check(deltas.length === 0, 'a horizontal lock ignores a later vertical move');
  check(!later.consume, 'and still does not eat the gesture');
}

{
  const { s, deltas } = harness();
  s.start({ x: 40, y: 40, touches: 2 });
  s.move({ x: 40, y: 120, touches: 2 });
  check(deltas.length === 0, 'pinch / two-finger does not scroll');
}

{
  const { s, deltas } = harness();
  s.start({ x: 40, y: 40, touches: 1 });
  s.move({ x: 40, y: 80, touches: 1 });
  s.move({ x: 40, y: 120, touches: 2 });
  check(deltas.reduce((a, b) => a + b, 0) === -40,
        'a second finger mid-swipe stops further scrolling');
}

{
  const { s, deltas } = harness();
  swipe(s, { x: 20, y: 80 }, { x: 120, y: 84 });  // horizontal, lock
  swipe(s, { x: 40, y: 40 }, { x: 40, y: 100 });  // next gesture
  const total = deltas.reduce((a, b) => a + b, 0);
  check(total === -60, 'end() clears the lock for the next gesture', `(${total})`);
}

{
  const { s, deltas } = harness();
  const consumed = swipe(s, { x: 40, y: 40 }, { x: 40, y: 100 });
  check(consumed, 'a committed vertical swipe is consumed (no page bounce)');
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
