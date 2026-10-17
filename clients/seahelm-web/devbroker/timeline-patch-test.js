// timeline-patch-test.js — a new message must touch the tail, not the list.
//
// Run:  node devbroker/timeline-patch-test.js
'use strict';

const { plan } = require('../timeline-patch.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};
const it = (id, html) => ({ id, html: html == null ? `<div>${id}</div>` : html });
const rows = (n, from = 1) => Array.from({ length: n }, (_, i) => it(`r${from + i}`));
// Apply a plan to a list the way the page applies it to the DOM.
const apply = (prev, p) => prev.slice(p.dropFront, prev.length - p.removeTail).concat(p.append);
const ids = (list) => list.map(x => x.id).join(',');

console.log('timeline patch');

{
  const prev = rows(10);
  const next = rows(11);
  const p = plan(prev, next);
  check(p && p.dropFront === 0 && p.removeTail === 0 && ids(p.append) === 'r11',
    'a new message only appends', JSON.stringify(p));
}

{
  // r10 was the newest, still breathing; r11 arrives and r10 stops.
  const prev = rows(9).concat([it('r10', '<div class="live">r10</div>')]);
  const next = rows(11);
  const p = plan(prev, next);
  check(p && p.removeTail === 1 && ids(p.append) === 'r10,r11',
    'the line that loses `live` is redrawn with the new one', JSON.stringify(p));
}

{
  // A lone call, then a second one: the two fold into a run keyed by the first.
  const prev = rows(9).concat([it('r10')]);
  const next = rows(9).concat([it('t10', '<div>Read ×2</div>')]);
  const p = plan(prev, next);
  check(p && p.removeTail === 1 && ids(p.append) === 't10', 'a call joining another folds them', JSON.stringify(p));
}

{
  // The run grows: same key, new count.
  const prev = rows(9).concat([it('t10', '<div>Read ×2</div>')]);
  const next = rows(9).concat([it('t10', '<div>Read ×3</div>')]);
  const p = plan(prev, next);
  check(p && p.removeTail === 1 && p.append.length === 1 && p.append[0].html.includes('×3'),
    'a growing run is rewritten in place', JSON.stringify(p));
}

{
  // Prose the Mac flushed late lands above the calls it introduces.
  const prev = rows(20);
  const next = rows(17).concat([it('r99'), it('r18'), it('r19'), it('r20')]);
  const p = plan(prev, next);
  check(p && p.removeTail === 3 && ids(p.append) === 'r99,r18,r19,r20',
    'a late message replaces only what is below it', JSON.stringify(p));
  check(ids(apply(prev, p)) === ids(next), 'and the result is the new list');
}

{
  // The window moved down: rows above it have gone.
  const prev = rows(10);
  const next = rows(10, 3);
  const p = plan(prev, next);
  check(p && p.dropFront === 2 && ids(apply(prev, p)) === ids(next), 'the window sliding drops from the front', JSON.stringify(p));
}

{
  check(plan(rows(10), rows(10, 50)) === null, 'nothing in common rebuilds');
  check(plan([], rows(3)) === null, 'nothing on screen rebuilds');
  check(plan(rows(3), []) === null, 'nothing to show rebuilds');
  // History paged in above: the first row is new.
  check(plan(rows(10, 5), rows(14)) === null, 'history paged in above rebuilds');
  // The header changed (Loading… → No earlier messages): rebuilt, it is rare.
  check(plan([it('top', 'a')].concat(rows(5)), [it('top', 'b')].concat(rows(5))) === null,
    'a changed first item rebuilds');
}

{
  // An opened group near the top changes most of the list's tail.
  const prev = rows(10);
  const next = rows(2).concat([it('r3', '<div>open</div>')]).concat(rows(7, 4));
  check(plan(prev, next) === null, 'replacing most of the list rebuilds instead');
}

{
  // Fuzz: whatever the plan, applying it must yield the new list.
  let seed = 7;
  const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
  let bad = 0;
  for (let round = 0; round < 500; round++) {
    const prev = rows(5 + rnd(30));
    let next = prev.slice(rnd(3));
    if (rnd(2)) next = next.slice(0, next.length - rnd(4));
    if (rnd(2) && next.length) next[next.length - 1] = it(next[next.length - 1].id, '<div>changed</div>');
    next = next.concat(rows(rnd(4), 100 + round * 10));
    if (rnd(4) === 0 && next.length > 3) next.splice(next.length - 2, 0, it(`late${round}`));
    const p = plan(prev, next);
    if (p && ids(apply(prev, p)) !== ids(next)) bad++;
    if (p && apply(prev, p).some((x, i) => x.html !== next[i].html)) bad++;
  }
  check(bad === 0, 'applying any plan yields exactly the new list', `${bad} wrong`);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
