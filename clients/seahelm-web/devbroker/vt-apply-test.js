// vt-apply-test.js — VT frames must apply in order, including the write itself.
//
// Run:  node devbroker/vt-apply-test.js
//
// Inflation was already chained; term.write() was not. A snapshot's reset()
// could land while the previous write was still draining, which is how a TUI
// prompt's cursor ended up off the input box.
'use strict';

const { createApplyQueue, writeTerminal } = require('../vt-apply.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};

function flush() {
  return new Promise((resolve) => setImmediate(resolve));
}

console.log('vt apply');

{
  let done = false;
  const term = {
    write(_bytes, cb) { setTimeout(() => { done = true; if (cb) cb(); }, 0); },
  };
  const p = writeTerminal(term, new Uint8Array([1]));
  check(done === false, 'writeTerminal does not resolve before the write callback');
  Promise.resolve(p).then(() => {
    check(done === true, 'and resolves once the callback fires');
    afterWriteTerminal();
  });
}

function afterWriteTerminal() {
  {
    let called = false;
    writeTerminal({ write() { called = true; } }, new Uint8Array(0)).then(() => {
      check(called === false, 'an empty payload does not call write');
      afterEmpty();
    });
  }
}

function afterEmpty() {
  const order = [];
  const q = createApplyQueue({ maxData: 8 });
  let finishSnap;
  q.enqueue('p', 'vt.snapshot', () => new Promise((resolve) => {
    order.push('snap-start');
    finishSnap = () => { order.push('snap-end'); resolve(); };
  }));
  q.enqueue('p', 'vt.data', async () => { order.push('data'); });
  flush().then(() => {
    check(order.join(',') === 'snap-start',
          'vt.data waits for an in-flight snapshot write', `(${order.join(',')})`);
    finishSnap();
    return q.enqueue('p', 'vt.data', async () => {});
  }).then(() => flush()).then(() => {
    check(order.join(',') === 'snap-start,snap-end,data',
          'then the waiting frame applies', `(${order.join(',')})`);
    afterSerialize();
  });
}

function afterSerialize() {
  const dropped = [];
  const q = createApplyQueue({
    maxData: 2,
    onDrop: (key) => dropped.push(key),
  });
  let release;
  const hold = () => new Promise((r) => { release = r; });
  q.enqueue('p', 'vt.data', hold);
  q.enqueue('p', 'vt.data', async () => {});
  q.enqueue('p', 'vt.data', async () => {});
  flush().then(() => {
    check(dropped.length === 1 && dropped[0] === 'p',
          'excess vt.data is dropped once the queue is full');
    q.enqueue('p', 'vt.snapshot', async () => {});
    check(dropped.length === 1, 'a snapshot is never dropped');
    release();
    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
  });
}
