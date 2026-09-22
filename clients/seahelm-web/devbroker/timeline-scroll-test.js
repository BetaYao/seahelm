// timeline-scroll-test.js — reading the timeline must survive a repaint.
//
// Run:  node devbroker/timeline-scroll-test.js
//
// Each case is a repaint: a view + row layout before, the same after whatever
// the new event did to the list, and where `scrollTop` should end up.
'use strict';

const { capture, restore } = require('../timeline-scroll.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};

const SLOP = 48;

/** Rows of equal height, seq `n` at index `n`, so tops are predictable. */
function layout(seqs, height, top0 = 0) {
  const tops = seqs.map((_, i) => top0 + i * height);
  return {
    rows: {
      length: seqs.length,
      seqAt: (i) => seqs[i],
      topAt: (i) => tops[i],
    },
    topOf: (seq) => {
      const i = seqs.indexOf(seq);
      return i < 0 ? null : tops[i];
    },
    height: top0 + seqs.length * height,
  };
}

console.log('timeline scroll');

{
  // At the end: the next event should arrive on screen.
  const before = layout([1, 2, 3], 100);
  const view = { scrollTop: 100, scrollHeight: 300, clientHeight: 200 };
  const cap = capture(view, before.rows, SLOP);
  check(cap.follow === true, 'sitting at the bottom follows');
  const after = layout([1, 2, 3, 4], 100);
  check(restore({ scrollHeight: after.height }, cap, after.topOf) === 400,
    'following lands at the new end');
}

{
  // Within `slop` of the end still counts — a phone never lands on an integer.
  const before = layout([1, 2, 3], 100);
  const cap = capture({ scrollTop: 70, scrollHeight: 300, clientHeight: 200 }, before.rows, SLOP);
  check(cap.follow === true, 'a few px short of the end still follows');
}

{
  // iOS rubber-band past the end reports a negative gap.
  const before = layout([1, 2, 3], 100);
  const cap = capture({ scrollTop: 140, scrollHeight: 300, clientHeight: 200 }, before.rows, SLOP);
  check(cap.follow === true, 'overscrolling past the end follows');
}

{
  // The bug: reading in the middle, a tool call repaints the list.
  const before = layout([1, 2, 3, 4, 5], 100);
  const view = { scrollTop: 220, scrollHeight: 500, clientHeight: 200 };
  const cap = capture(view, before.rows, SLOP);
  check(cap.follow === false, 'reading above the end does not follow');
  check(cap.seq === 3 && cap.offset === -20, 'anchors on the row under the top edge',
    `${cap.seq}/${cap.offset}`);
  const after = layout([1, 2, 3, 4, 5, 6], 100);
  check(restore({ scrollHeight: after.height }, cap, after.topOf) === 220,
    'appending below leaves the reader where they were');
}

{
  // A page of history lands above the reader: the anchor row moves down by it.
  const before = layout([5, 6, 7, 8], 100);
  const cap = capture({ scrollTop: 150, scrollHeight: 400, clientHeight: 200 }, before.rows, SLOP);
  check(cap.seq === 6, 'anchor is the row spanning the top edge', String(cap.seq));
  const after = layout([1, 2, 3, 4, 5, 6, 7, 8], 100);
  check(restore({ scrollHeight: after.height }, cap, after.topOf) === 550,
    'prepended history pushes scrollTop down by exactly its height');
}

{
  // A "Loading earlier messages…" line is inserted above everything.
  const before = layout([1, 2, 3, 4], 100);
  const cap = capture({ scrollTop: 200, scrollHeight: 400, clientHeight: 100 }, before.rows, SLOP);
  const after = layout([1, 2, 3, 4], 100, 30);
  check(restore({ scrollHeight: after.height }, cap, after.topOf) === 230,
    'a banner above the rows does not shift the text');
}

{
  // The agent's prose is stamped when it was written, so it can sort in above
  // the tool call that already arrived — an insert, not an append.
  const before = layout([1, 2, 3, 4, 5, 6], 100);
  const cap = capture({ scrollTop: 300, scrollHeight: 600, clientHeight: 100 }, before.rows, SLOP);
  check(cap.seq === 4, 'anchors on the row at the top edge', String(cap.seq));
  const after = layout([1, 2, 9, 3, 4, 5, 6], 100);
  check(restore({ scrollHeight: after.height }, cap, after.topOf) === 400,
    'a line inserted above the anchor carries it down');
}

{
  // MESSAGE_CAP evicted the row we were on.
  const before = layout([1, 2, 3, 4, 5], 100);
  const cap = capture({ scrollTop: 150, scrollHeight: 500, clientHeight: 200 }, before.rows, SLOP);
  check(cap.fromBottom === 350, 'the distance from the end is captured too', String(cap.fromBottom));
  const after = layout([4, 5, 6], 100);
  check(restore({ scrollHeight: after.height }, cap, after.topOf) === 0,
    'an evicted anchor falls back to the distance from the end, clamped at 0');
}

{
  // Nothing rendered yet (empty pane, or the hint row).
  const cap = capture({ scrollTop: 400, scrollHeight: 900, clientHeight: 200 },
    { length: 0, seqAt: () => 0, topAt: () => 0 }, SLOP);
  check(cap.follow === false && cap.seq === null, 'no rows means no anchor');
  check(restore({ scrollHeight: 1000 }, cap, () => null) === 500,
    'without rows the distance from the end is all there is');
}

{
  // Shorter than the viewport: there is no "above the bottom" to be in.
  const before = layout([1], 40);
  const cap = capture({ scrollTop: 0, scrollHeight: 40, clientHeight: 600 }, before.rows, SLOP);
  check(cap.follow === true, 'content too short to scroll always follows');
}

{
  // The binary search must agree with a linear scan at every position.
  const seqs = [];
  for (let i = 0; i < 64; i++) seqs.push(i * 3);
  const l = layout(seqs, 17);
  let agree = true;
  for (let top = 0; top < 64 * 17; top += 1) {
    const cap = capture({ scrollTop: top, scrollHeight: 100000, clientHeight: 200 }, l.rows, SLOP);
    let want = 0;
    for (let i = 0; i < seqs.length; i++) if (l.rows.topAt(i) <= top) want = i;
    if (cap.seq !== seqs[want]) { agree = false; break; }
  }
  check(agree, 'the search picks the same row a linear scan would');
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
